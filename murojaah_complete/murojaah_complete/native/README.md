# Murojaah Native Core

Production C++ implementation of the on-device STT path:
**audio thread → resample → ring buffer → VAD ↔ hop thread → mel → ORT → CTC**.

## Files

| File | Purpose |
|---|---|
| `murojaah_core.h/.cpp` | `extern "C"` ABI consumed by Dart via `dart:ffi`; orchestrator. |
| `ring_buffer.h` | Lock-free SPSC ring buffer (audio thread writes, hop reads). |
| `dsp.h/.cpp` | Windowed-sinc resampler (→16 kHz), radix-2 FFT, log-mel-80. |
| `vad.h/.cpp` | Energy VAD with hysteresis (drop-in for WebRTC-VAD). |
| `ctc_decode.h/.cpp` | Greedy CTC decoder + confidence; loads `vocab.tsv`. |
| `CMakeLists.txt` | Android shared-lib build (`libmurojaah_core.so`). |

## What's real

The whole pipeline is implemented end-to-end. The only external dependency is
**ONNX Runtime Mobile** (and Android/iOS platform libs). Drop in:

- `model.onnx` (your exported model — `training/export_onnx.py`)
- `vocab.tsv` (written alongside it: `<id>\t<utf8_token>\n`)

…in the same directory, point `mj_create("/abs/path/to/model.onnx", 1)` at it,
and `mj_infer_hop` returns decoded Arabic text.

The orchestrator auto-detects model input shape:
- **rank-2** `[1, T_audio]` → raw 16 kHz audio (e.g. Wav2Vec2-CTC).
- **rank-3** `[1, T, 80]` → log-mel features (Conformer-CTC and friends).

## Build (Android)

1. Grab an ONNX Runtime Android prebuilt:
   ```bash
   # one option among several — adapt to your release
   wget https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-android-1.18.0.aar
   unzip -o onnxruntime-android-1.18.0.aar -d third_party/onnxruntime-android
   ```
2. Uncomment and adjust the `ORT_DIR` block in `CMakeLists.txt`.
3. Wire the CMake path into `android/app/build.gradle`:
   ```gradle
   android {
     externalNativeBuild { cmake { path = "../../native/CMakeLists.txt" } }
     defaultConfig {
       externalNativeBuild { cmake { cppFlags "-std=c++17" } }
       ndk { abiFilters 'arm64-v8a', 'armeabi-v7a' }
     }
   }
   ```
4. Add mic permission to `AndroidManifest.xml`:
   ```xml
   <uses-permission android:name="android.permission.RECORD_AUDIO"/>
   ```

## Build (iOS)

1. Add `*.cpp`/`*.h` to the Runner target in Xcode.
2. Drag in `onnxruntime.xcframework` (linked via "Frameworks, Libraries…").
3. Export `mj_*` symbols (see comments in `CMakeLists.txt`).
4. Add `NSMicrophoneUsageDescription` to `Info.plist`.

## Notes on quality

- **Resampler**: 32-tap Kaiser/Hann-windowed sinc with bandlimit factor. Suitable
  for 44.1k/48k → 16k. For pathological rates, swap in `libsamplerate` —
  `Resampler::process` is a drop-in interface.
- **VAD**: energy + hysteresis. Tune `enter_db` / `exit_db` per device (mic
  sensitivity varies). For noisy environments, replace with `libfvad`.
- **FFT**: textbook radix-2 Cooley-Tukey. ~0.3 ms per 512-point FFT on a mid-tier
  ARMv8 — comfortably under budget at ~5 hops/s. Replace with `pffft`/`kissfft`
  if you need cycle-accurate budgeting on low-end SoCs.
- **CTC**: greedy decode. For lower WER, add prefix-beam search and bias the
  beam toward the expected next words of the target ayah (the closed-vocabulary
  unlock from the blueprint — `AlignmentService` on the Dart side already knows
  the next expected word).
