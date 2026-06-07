# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Murojaah — an **offline, real-time Qur'an memorization checker**. As the user recites, correct words turn **green**, wrong words **red**, and not-yet-reached words stay **gray**. The whole pipeline runs on-device: mic → C++ DSP → CTC inference (ONNX Runtime) → semi-global text alignment → per-word coloring in Flutter.

`murojaah_blueprint.md` (repo root) is the authoritative design doc. Read it before non-trivial changes — it explains *why* CTC (not Whisper), why semi-global alignment, the latency budget, and the battery/thermal strategy. Most code here is a faithful implementation of that blueprint.

## Repository layout — three overlay bundles, not three projects

This repo is **not a git repo** and is **not a single buildable project**. It is one runnable Flutter app plus two "drop-on-top" upgrade bundles. Every bundle is double-nested (`X/X/...`):

| Path | Role |
|---|---|
| `murojaah_app/murojaah_app/` | **The actual app.** Flutter + a native C++ scaffold. Runs today via simulation/manual input with no ML setup. |
| `murojaah_complete/murojaah_complete/` | Overlay bundle: full C++ STT core (DSP+VAD+CTC), Python data pipeline (full mushaf → SQLite), Python training (Wav2Vec2-CTC → ONNX), and Flutter patches. Files overlay onto `murojaah_app/`. |
| `murojaah_advanced/murojaah_advanced/` | Overlay bundle v2: prefix-beam CTC decoder + lexicon bias, native Oboe/AVAudioEngine mic capture, and a desktop test harness. Overlays/replaces the v1 native files. |

**Overlay bundles are not standalone.** Their files (e.g. `murojaah_complete/.../native/*.cpp`, `flutter_patches/lib/...`) are meant to be copied into `murojaah_app/murojaah_app/` to replace scaffold/TODO versions. Each bundle's `README.md` lists exact source→destination mappings. When asked to "wire up the real model" or "add beam search," you are integrating overlay files into the app, not editing in place.

## Build & run

Everything is run from `murojaah_app/murojaah_app/`. The platform folders (`android/`, `ios/`) are **not committed** — they're generated on first setup.

```bash
cd murojaah_app/murojaah_app
flutter create .      # generate android/ ios/ platform folders (first time only)
flutter pub get
flutter run           # tap Simulasi (demo) or Uji manual (type Arabic)
```

- **No ML or native build is required to run** — `SimulatedStt` drives the demo and manual text input works immediately. The **Mic** button needs the model + native core (below).
- **Desktop testing:** add `sqflite_common_ffi`, set `databaseFactory = databaseFactoryFfi;` in `main()`. On-device sqflite works as-is.
- Tests: `flutter test` (run a single file with `flutter test test/<name>_test.dart`). No test files ship yet.

### Native core (only when enabling the Mic path)
- **Android:** point `ORT_DIR` in `native/CMakeLists.txt` at an `onnxruntime-android` prebuilt; wire CMake into `android/app/build.gradle` (snippet in the CMakeLists / advanced bundle README). `flutter build apk`.
- **iOS:** add `native/*.{cpp,mm}` to the Runner target in Xcode, link `onnxruntime.xcframework`; keep `DynamicLibrary.process()` (symbols live in the process).
- **Desktop C++ test harness** (advanced bundle): `cmake -DCMAKE_BUILD_TYPE=Release -DORT_DIR=/path/to/onnxruntime -f ../CMakeLists_test.txt ..` then `make`. `vocab.tsv` must sit next to the `.onnx`.

### Python pipelines (in `murojaah_complete/murojaah_complete/`)
- **Data:** `cd data_pipeline && python build_quran_db.py quran-uthmani.xml -o ../flutter_patches/assets/quran.db` (stdlib only, no pip). `python normalizer.py` runs a Dart-parity self-check — **run it before building the DB**.
- **Training:** `cd training && pip install -r requirements.txt && python train_wav2vec2_ctc.py --subset 0.05` (validation run), then `python export_onnx.py --ckpt ./out/wav2vec2-quran --out ./out/export`. Needs a GPU; `--subset` is for fast end-to-end sanity checks.

## Architecture (the parts that span files)

Data flow, per the blueprint:
```
mic → native C++ (ring buffer → resample 16k → VAD gate → log-mel → ONNX CTC → decode)
    → Dart FFI → SttEngine (cumulative partial transcript)
    → AlignmentService (semi-global DP) → StatusStabilizer → MurojaahEngine → UI RichText
```

Key contracts to preserve when modifying:

- **`SttEngine` (`lib/stt/stt_engine.dart`)** emits a *cumulative* partial transcript (full text so far, space-separated) on a `Stream<String>`. Two impls: `SimulatedStt` (demo, no model) and `OnnxStt` (FFI → native). Swapping one for the other is the *only* change to go from demo to offline-AI — keep them interchangeable behind this interface.

- **`AlignmentService` (`lib/core/alignment_service.dart`)** is the heart and is **production-final**. It aligns the growing hypothesis against the *fixed, known* target ayah using **semi-global DP** (free leading/trailing target gaps) — recitation "snaps" onto the right region. Words: matched→correct, matched-to-different→wrong, skipped-before-frontier→wrong, after-frontier→waiting. `StatusStabilizer` requires a status to hold for N hops before latching (anti-flicker); "waiting" never latches.

- **`ArabicNormalizer` (`lib/core/arabic_normalizer.dart`)** produces a **loose key** (harakat/marks stripped, letter variants folded — forgiving match) and a **strict key** (harakat preserved — Tajweed-precise mode). **`data_pipeline/normalizer.py` is a parity mirror of this** — if you change normalization rules in one, change both, and the `python normalizer.py` self-check guards the drift.

- **`MurojaahEngine` (`lib/engine/murojaah_engine.dart`)** is a `ChangeNotifier` orchestrator: STT transcript (or manual text) → `align()` → `stab.commit()` → `notifyListeners()`. UI rebuilds only the `RichText`.

- **Closed-vocabulary unlock:** the target ayah is always known. The advanced bundle's lexicon-biased beam decoder uses this — `mj_set_target()` feeds the expected next words to the C++ decoder so beams matching expected words get a log-prob bonus. Greedy decode is the fallback when no target is set.

### Performance design (mostly aspirational — see blueprint STEP 4)
The design's enemy is continuous inference on mid-range SoCs. The native/FFI layer enforces some of this today (**mmap the int8 model** — load ONNX from a file path, never bytes; **reuse preallocated buffers** — native ring/scratch + Dart `malloc`'d pointers, no per-hop allocation; **decouple capture ~30 ms frames from inference ~200 ms hop**; **VAD-gate every hop** so silence skips the encoder). Other blueprint goals are **not yet implemented**: the Dart hop loop / `align()` currently runs on the **main isolate** (`MurojaahEngine._apply` → `setState`), not a background isolate, and there is no thermal governor yet. Don't assume these exist; preserve the ones that do and treat the rest as the target.

## Data
- The corpus is **seeded programmatically** from `lib/data/quran_seed.dart` (6 short surahs: Fatihah + parts of juz 30) on first launch — no asset needed to run. The SQLite schema (`surahs`/`ayahs`/`words` with loose+strict keys precomputed) already supports the full 6,236-ayah mushaf; the `complete` bundle's data pipeline builds that DB. Normalization is precomputed at DB-build time, never at runtime.

## Status of each layer (from the app README)
Production: normalizer, alignment+stabilizer, SQLite schema/repository, engine, UI. **Wired but needs model+native build:** `OnnxStt`. **Scaffold with `// TODO`:** the v1 `native/murojaah_core.cpp` (log-mel + CTC decode) — the full implementation lives in the `complete` bundle's `native/`.

## Conventions
- User-facing UI strings are in **Indonesian** (e.g. "Simulasi", "Uji manual", "Mode ketat (harakat)"); code/comments are English. Keep new UI text Indonesian.
- Arabic renders RTL; the intended fonts (Amiri etc.) are optional `.ttf` drops in `assets/fonts/` — without them Arabic falls back to the system font.
