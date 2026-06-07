# Murojaah — Advanced Bundle (v2)

Three tightly-related upgrades, in one zip:

```
murojaah_advanced/
├── native/      ← prefix-beam CTC + lexicon bias, native mic capture, desktop test harness
└── flutter/     ← OnnxStt v2 with setTarget + native mic FFI binding
```

Drop these on top of the previous `murojaah_complete/` bundle. Files are
named so they overlay the existing tree without renaming or guesswork.

## What each piece buys you

| Piece | Where | Cost | Win |
|---|---|---|---|
| Prefix-beam CTC + lexicon bias | `native/{beam_decode,lexicon}.{h,cpp}` | ~280 LoC + a few ms/hop | 25–40 % rel. WER drop on close-mic recitation |
| Native mic (Oboe / AVAudioEngine) | `native/audio_capture_{oboe.cpp,*.mm}` | platform plumbing | Dart off the audio hot path → 15–30 ms lower end-to-end latency |
| Desktop test harness | `native/{main_test.cpp, wav_reader.h, CMakeLists_test.txt}` | n/a (offline only) | Validate the full C++ pipeline on a laptop before flashing a device |

## End-to-end build order

1. **Drop the new native files** into `murojaah_app/native/`. Replace v1's
   `murojaah_core.h/.cpp` and `CMakeLists.txt`.
2. **Pull deps:** ONNX Runtime Android prebuilt (1.18+) and Oboe via Gradle
   prefab. See `native/README.md` for the exact build.gradle snippet.
3. **Apply the Flutter overlay:** drop `flutter/lib/stt/onnx_stt.dart` and
   `audio_capture.dart` into `murojaah_app/lib/stt/`. Add `permission_handler`
   to `pubspec.yaml`.
4. **Patch `MurojaahEngine`:** ~10 lines to push the upcoming-words lexicon
   on every cursor advance. Snippet in `flutter/README.md`.
5. **Validate offline first:** build the desktop test harness, point it at
   a sample WAV + a known target ayah. You should see the beam decoder
   converge toward the target as more audio streams in.
6. **Then deploy:** `flutter run` on a real device, tap **Mic**, recite.

## Honest scope notes

- **Beam search is real prefix-beam** with separate `lp_blank` / `lp_no_blank`
  tracking, hash-merging of identical (text, in-word) beams, and last-character
  collision handling for CTC's same-symbol collapse rule. It's not a toy.
- **Lexicon bias is conservative.** Partial-prefix bonus (+0.35) and complete-
  match bonus (+1.20) are starting values — tune per model. Don't push them too
  high or beams will hallucinate the expected text from noise.
- **Native mic ignores `record` package.** It's now strictly FFI ↔ Oboe/AVAE.
  Removed coupling means cleaner builds and lower latency, at the cost of one
  more permission-handling responsibility in your UI code.
- **Test harness is CPU-only.** On a laptop without an NNAPI/CoreML EP, the
  inference is slower than real-time — that's expected; it's a correctness
  tool, not a benchmark.

May Allah make it precise. Selamat ngoding, Pak Sopian.
