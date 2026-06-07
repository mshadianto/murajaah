# Murojaah — Complete Offline-AI Bundle

The full set of pieces that turn the Murojaah Flutter scaffold from
*"runnable demo via simulation"* into *"100% offline, on-device AI"* as
specified in the original blueprint.

```
murojaah_complete/
├── native/             ← full C++ STT core (DSP + VAD + ORT + CTC)
├── data_pipeline/      ← Python: full mushaf → SQLite asset
├── training/           ← Python: Wav2Vec2-CTC fine-tune + ONNX export
└── flutter_patches/    ← overlays on top of murojaah_app/
```

## End-to-end order of operations

Pick the order based on what you want to validate first.

### Path A — see the engine work end-to-end with a real model

1. **Train.** `cd training && python train_wav2vec2_ctc.py --subset 0.05`
   (≈2 h on Colab A100; sanity check). Then export + quantize:
   `python export_onnx.py --ckpt ./out/wav2vec2-quran --out ./out/export`.
2. **Build the native core.** Drop `native/*` into `murojaah_app/native/` (replacing
   the scaffold), follow `native/README.md` to link ONNX Runtime.
3. **Bundle assets.** Copy `out/export/quran_ctc_int8.onnx` + `vocab.tsv` into
   `murojaah_app/assets/models/`. Apply `flutter_patches/` overlay.
4. **Run.** `flutter run` → tap Mic → speak an ayah → green words light up,
   all on-device.

### Path B — ship the full mushaf first, AI later

1. **Build the DB.** Download Tanzil Uthmani XML, then
   `cd data_pipeline && python build_quran_db.py quran-uthmani.xml -o ../flutter_patches/assets/quran.db`.
2. **Apply Flutter patches.** Drop the new `quran_repository.dart`, declare
   `assets/quran.db` in `pubspec.yaml`. Run — now all 6,236 ayat are usable
   via Simulasi + manual input.
3. **Train + wire AI later** (Path A from step 1).

## What's actually in each module

### `native/` — production C++
- **`murojaah_core.cpp`** — orchestrator: audio thread does int16→float +
  resample + ring write + VAD; hop thread does mel + ORT.Run + CTC decode.
- **`dsp.{h,cpp}`** — windowed-sinc resampler (any rate → 16k), radix-2 FFT,
  Slaney log-mel-80.
- **`vad.{h,cpp}`** — energy VAD with hysteresis.
- **`ctc_decode.{h,cpp}`** — greedy CTC + confidence + `vocab.tsv` loader.
- **`ring_buffer.h`** — lock-free SPSC ring (audio thread never blocks).
- Auto-detects model input shape: raw audio `[1, T]` (Wav2Vec2-CTC) or
  log-mel `[1, T, 80]` (Conformer-CTC etc.).

### `data_pipeline/` — full mushaf
- **`normalizer.py`** — Python mirror of `ArabicNormalizer` (parity-tested).
- **`build_quran_db.py`** — Tanzil XML / `quran-json` → SQLite, schema matches
  the app's repository exactly, ayah counts cross-checked against the
  canonical metadata baked into the script.

### `training/` — Wav2Vec2-CTC
- **`train_wav2vec2_ctc.py`** — HuggingFace Trainer on Tarteel EveryAyah,
  XLSR-53-Arabic base, harakat-stripped CTC vocab.
- **`export_onnx.py`** — ONNX export with dynamic time axis + int8 dynamic
  quantization + `vocab.tsv` write (consumed by the C++ decoder).
- **`convert_to_ort.py`** — optional ONNX → ORT format conversion for
  mmap-friendly mobile loading.

### `flutter_patches/` — drop-in overlays
- **`lib/data/quran_repository.dart`** — loads bundled `assets/quran.db` if
  present; falls back to programmatic seed for builds without the asset.
- **`lib/stt/asset_loader.dart`** — copies bundled model + vocab to a real
  file path (ORT mmaps from disk, not bytes).
- **`README.md`** — exact pubspec/page diffs.

## Honest scope notes

- The training loop assumes you have GPU time. Expect non-trivial compute for
  full corpus training; the `--subset` flag exists for fast validation runs.
- The DSP modules are correct and self-contained, but they're *not* SIMD-tuned
  yet — for low-end devices, swap the FFT for `pffft` and the resampler for
  `libsamplerate` (interfaces are designed to be drop-in).
- The CTC decoder is greedy. For lower WER, add prefix-beam search biased
  toward the expected next words of the target ayah — `AlignmentService` on
  the Dart side already knows them, so plumbing that bias through is the
  next-tier accuracy win documented in the blueprint.

May Allah make it easy. Selamat ngoding, Pak Sopian.
