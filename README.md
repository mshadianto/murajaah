# Murojaah

> Repo name uses **murAjaah** (with 'a'); code & package identifiers use **murOjaah** (with 'o'). Both are valid romanizations of مراجعة and are intentional — don't "fix" one to match the other.

Murojaah — offline, real-time Qur'an memorization checker. As the reciter speaks, correct words turn green, wrong red, not-yet-reached stay gray. Full pipeline (capture → DSP → CTC inference → semi-global alignment → per-word coloring) runs 100% on-device. No internet, no telemetry, no audio leaves the phone.

![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-WIP-orange)

## What's in this repo

```
.
├── murojaah_app/murojaah_app/   ← runnable Flutter app (DOUBLE-NESTED, intentional)
├── murojaah_complete/           ← overlay bundle: native C++ + training + data pipeline
├── murojaah_advanced/           ← overlay bundle v2: beam decoder + native mic + test harness
├── murojaah_blueprint.md        ← architecture & "why" doc — read first
└── CLAUDE.md                    ← orientation for Claude Code / future contributors
```

> The two `murojaah_complete/` and `murojaah_advanced/` trees are **overlay bundles**, not standalone projects: their files are meant to be copied on top of `murojaah_app/murojaah_app/` to replace scaffold/`// TODO` versions. The app directory is double-nested on purpose.

## Quick start (zero ML setup)

```bash
cd murojaah_app/murojaah_app
flutter create .       # generate android/ + ios/
flutter pub get
flutter run
```

The **Simulasi** and **Uji manual** modes work immediately — no model required. The **Mic** button is gated until an overlay bundle is applied and a model is bundled (see below).

## Full offline AI

Going from "runnable demo" to "100% on-device AI" is three overlay steps:

1. **Apply `murojaah_complete/`** — drop in the full native C++ STT core (DSP + VAD + CTC), the Python data pipeline (full mushaf → SQLite), and the training scaffold. See [`murojaah_complete/murojaah_complete/README.md`](murojaah_complete/murojaah_complete/README.md).
2. **Build & ship the model** — fine-tune Wav2Vec2-CTC on Qur'an recitation and export to ONNX (int8) via `training/`, then bundle it under `assets/models/`. See [`murojaah_complete/murojaah_complete/training/README.md`](murojaah_complete/murojaah_complete/training/README.md).
3. **Apply `murojaah_advanced/`** — lexicon-biased prefix-beam decoder, native low-latency mic (Oboe / AVAudioEngine), and a desktop test harness. See [`murojaah_advanced/murojaah_advanced/README.md`](murojaah_advanced/murojaah_advanced/README.md).

## Architecture (TL;DR)

> Flutter's `dart:ffi` gives near-zero-overhead, zero-copy interop with a native C++ DSP/inference core. The real unlock is **closed-vocabulary forced alignment**: the target ayah is known, so the STT only has to *confirm* expected words and *flag* deviations, not guess open-vocabulary. A **semi-global alignment** DP snaps the growing partial transcript onto the correct region of the ayah, deciding green / red / gray per word.

Full reasoning — model choice (CTC, not Whisper), latency budget, battery/thermal strategy — is in [`murojaah_blueprint.md`](murojaah_blueprint.md). Read it first.

## Status

What works today vs. what's still aspirational:

- ✅ Flutter UI + `ChangeNotifier` engine + semi-global alignment
- ✅ Bahasa Indonesia UI strings, RTL Arabic rendering
- ✅ Seeded SQLite (6 surahs), simulation mode runs with no ML
- ⚠️ Mic path gated — needs overlay applied + a bundled model
- ⚠️ Hop loop still on the main isolate (blueprint goal: background isolate)
- ⚠️ No thermal governor yet

## Credits

Qur'an text from the [Tanzil Project](https://tanzil.net), licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). The text is verbatim — no modifications. Built into the app's SQLite asset via `data_pipeline/build_quran_db.py`.

## License

MIT — see [LICENSE](LICENSE).

---

Built for muraja'ah of Qur'an. May Allah accept.
