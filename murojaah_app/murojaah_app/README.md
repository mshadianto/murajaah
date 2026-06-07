# Murojaah — Offline Real-Time Qur'an Memorization

Flutter implementation of the Murojaah blueprint: as you recite, correct words
turn **green**, wrong words **red**, and not-yet-reached words stay **gray** —
driven by a semi-global alignment engine over the Uthmani script in local SQLite.

> **Runs today, no ML setup needed.** `flutter run` gives you a working app via
> **Simulasi** (auto demo) and **Uji manual** (type Arabic — works with or
> without harakat). The **Mic** button uses the on-device ONNX path, which
> activates once you drop in a model + build the native core (steps below).

---

## Quick start

```bash
flutter create .          # generate android/ ios/ platform folders into this dir
flutter pub get
flutter run
```

Then tap **Simulasi** to watch the engine color a recitation live, or type into
**Uji manual** (e.g. `قل هو الله احد`). Toggle **Mode ketat (harakat)** to switch
between forgiving and Tajweed-precise matching.

> Desktop testing: add `sqflite_common_ffi` and call `databaseFactory = databaseFactoryFfi;`
> in `main()`. On real Android/iOS devices, sqflite works as-is.

---

## What's real vs. stand-in

| Layer | Status |
|---|---|
| Arabic normalizer (`lib/core/arabic_normalizer.dart`) | **Production** |
| Semi-global alignment + stabilizer (`lib/core/alignment_service.dart`) | **Production** |
| SQLite schema + repository (`lib/data/`) | **Production** |
| Engine orchestrator (`lib/engine/`) | **Production** |
| UI (`lib/ui/`) | **Production** |
| `OnnxStt` FFI wrapper (`lib/stt/onnx_stt.dart`) | **Wired**, needs model + native build |
| Native C++ DSP/CTC (`native/`) | **Scaffold** — `// TODO` for log-mel + decode |
| `SimulatedStt` (`lib/stt/simulated_stt.dart`) | Demo driver (no model needed) |

The alignment/normalization/coloring is the hard part and it's final. Swapping
`SimulatedStt` → `OnnxStt` is the only change to go fully offline-AI.

---

## File map

```
lib/
  main.dart                     app entry, opens the DB
  core/
    word_token.dart             WordToken + WordStatus
    arabic_normalizer.dart      loose/strict keys (diacritics handling)
    alignment_service.dart      semi-global DP + StatusStabilizer
  data/
    quran_seed.dart             verified short surahs (Fatihah + juz 30)
    quran_repository.dart       sqflite schema + first-run seeding
  stt/
    stt_engine.dart             streaming STT interface
    simulated_stt.dart          demo transcript driver
    onnx_stt.dart               on-device FFI wrapper (ONNX + native)
  engine/
    murojaah_engine.dart        STT → align → stabilize → notify UI
  ui/
    app_theme.dart              colors + theme
    murojaah_page.dart          the screen
native/
  murojaah_core.h / .cpp        extern "C" core: ring buffer, VAD, log-mel, ORT
  CMakeLists.txt                Android native build
```

---

## Going fully offline-AI

### 1. The model
Export a streaming **CTC** acoustic model fine-tuned on Qur'an recitation to
**ONNX (int8)** — Wav2Vec2-CTC or Conformer-CTC (frame-synchronous → true
streaming, low latency). For accuracy refinement you can add a verifier pass with
Tarteel's `whisper-tiny-ar-quran` (Apache-2.0). Place the file at
`assets/models/quran_ctc_int8.onnx` and uncomment the `assets:` block in
`pubspec.yaml`. Implement `_resolveModelPath()` in `murojaah_page.dart` to copy
the asset to a file path (ORT mmaps from a path).

### 2. The native core
- **Android:** point `ORT_DIR` in `native/CMakeLists.txt` at an
  `onnxruntime-android` prebuilt and wire the CMake path into
  `android/app/build.gradle` (snippet in the CMakeLists). Fill the `// TODO`s in
  `murojaah_core.cpp`: resample→16k, WebRTC-VAD, log-mel (NEON), CTC decode.
- **iOS:** add `murojaah_core.{h,cpp}` to the Runner target in Xcode, link
  `onnxruntime.xcframework`, and keep `DynamicLibrary.process()` (symbols are in
  the process). CoreML EP targets the Neural Engine; the first run compiles once.

### 3. Mic capture
In `OnnxStt.start()` wire a low-latency PCM source and forward frames to
`feedPcm()` — see the commented `record` example, or use Oboe (Android) /
AVAudioEngine (iOS) via a platform channel. Add the mic permission:
- Android: `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
- iOS: `NSMicrophoneUsageDescription` in `Info.plist`

### 4. Performance (already designed for)
Inference runs on a ~200 ms hop (decoupled from the 30 ms capture frames),
VAD-gates silence, mmaps the int8 model, and reuses native + Dart buffers.
For production, move the hop loop to a background `Isolate` and add an adaptive
thermal governor (widen the hop under `ProcessInfo.thermalState` /
`PowerManager.getCurrentThermalStatus`).

---

## Notes
- Corpus is seeded from `quran_seed.dart` (6 short surahs). Swap in a full QPC
  Uthmani import to cover the whole mushaf — the schema already supports it.
- For the intended typography (Amiri / Fraunces / Plus Jakarta Sans), drop the
  `.ttf` files in `assets/fonts/` and uncomment the `fonts:` block in
  `pubspec.yaml`. Without them, Arabic still renders via the system font.
