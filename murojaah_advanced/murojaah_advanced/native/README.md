# Murojaah Native — v2 (beam decode + native mic + test harness)

Three additions on top of the previous native bundle. Drop the new files
into `murojaah_app/native/` (replacing the v1 `murojaah_core.h/.cpp` and
`CMakeLists.txt`).

## What's new

### 1. Lexicon-biased prefix beam decoder
- `beam_decode.{h,cpp}` — prefix-beam CTC with separate blank/non-blank
  log-probs (correct CTC collapse), top-K pruning per frame.
- `lexicon.{h,cpp}` — active expected-word matcher; `score(in_word)` returns
  log-prob bonuses for partial / complete matches.
- Wired into `murojaah_core.cpp` — `mj_set_target()` switches modes.

The accuracy unlock: at any moment the alignment cursor knows which words
*should* come next. We hand that list to the decoder; beams whose
in-progress word is heading toward (or matching) one of those expected
words get a log-prob bonus. Greedy still works as a fallback; when no
target is set, behaviour is identical to v1.

### 2. Native low-latency mic capture
- `audio_capture_oboe.cpp` — Android via Oboe, `InputPreset::VoiceRecognition`,
  `PerformanceMode::LowLatency`, Int16 mono. Audio thread pushes straight
  into `mj_push_pcm` — Dart is never on the hot path.
- `audio_capture.mm` — iOS via AVAudioEngine, `AVAudioSessionModeMeasurement`,
  10 ms preferred I/O buffer, Float32→Int16 conversion in the tap block.

Same `extern "C"` ABI on both platforms (`mj_mic_create / start / stop /
destroy`), so Dart binds them once via FFI and the same code path works
cross-platform.

### 3. Desktop offline test harness
- `main_test.cpp` + `wav_reader.h` — load a WAV, stream it through the
  pipeline, print incremental transcripts. Lets you validate the whole
  C++ stack on a laptop before touching a device.

## Build (Android)

```
# 1) Drop these files into murojaah_app/native/, replacing existing v1 ones.

# 2) Grab ONNX Runtime Android prebuilt (1.18+) and Oboe:
#    - ORT: https://github.com/microsoft/onnxruntime/releases
#    - Oboe: NDK r21+ ships it via prefab; add to app/build.gradle:
android {
  buildFeatures { prefab = true }
  externalNativeBuild { cmake { path = "../../native/CMakeLists.txt" } }
}
dependencies {
  implementation 'com.google.oboe:oboe:1.9.0'
}

# 3) flutter build apk
```

## Build (iOS)

Add to the Runner target in Xcode: every `*.cpp` plus `audio_capture.mm`.
Link `onnxruntime.xcframework` and `AVFoundation.framework`.

`Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Untuk mendengarkan bacaan murojaah secara offline.</string>
```

## Build the desktop test harness

```bash
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DORT_DIR=/path/to/onnxruntime-linux-x64-1.18.0 \
      -f ../CMakeLists_test.txt ..
make

# Greedy decode (no target):
./murojaah_test /path/to/quran_ctc_int8.onnx /path/to/sample.wav

# Beam-with-lexicon (loose-keyed Uthmani text expected):
./murojaah_test \
    /path/to/quran_ctc_int8.onnx \
    /path/to/sample.wav \
    --target "بسم الله الرحمن الرحيم"
```

`vocab.tsv` must sit next to the `.onnx` (same dir). Output looks like:

```
· loaded sample.wav — 16000 Hz, 1 ch, 47200 samples (2.95 s)
· engine ready, model = quran_ctc_int8.onnx
· target set (4 words) — beam search with lexicon bias
[ 1.21s hop#5 c=0.62] بسم الله
[ 2.01s hop#9 c=0.71] بسم الله الرحمن
[ 2.81s hop#13 c=0.78] بسم الله الرحمن الرحيم
─────────────────────────────────────────
FINAL  conf=0.812
بسم الله الرحمن الرحيم
```

## Files

| File | New / Updated |
|---|---|
| `beam_decode.{h,cpp}` | **new** — prefix-beam CTC decoder |
| `lexicon.{h,cpp}` | **new** — expected-word matcher |
| `murojaah_core.h` | **updated** — adds `mj_set_target` + mic ABI |
| `murojaah_core.cpp` | **updated** — wires BeamDecoder, mode switch |
| `audio_capture_oboe.cpp` | **new** — Android Oboe mic capture |
| `audio_capture.mm` | **new** — iOS AVAudioEngine mic capture |
| `main_test.cpp` | **new** — desktop test harness |
| `wav_reader.h` | **new** — tiny RIFF/WAV parser |
| `CMakeLists.txt` | **updated** — adds new modules + Oboe linkage |
| `CMakeLists_test.txt` | **new** — desktop test binary |
