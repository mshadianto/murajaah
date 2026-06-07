# Training — Wav2Vec2-CTC for Qur'anic ASR

Fine-tunes a Wav2Vec2 acoustic model with a CTC head on the
[Tarteel EveryAyah](https://huggingface.co/datasets/tarteel-ai/everyayah)
dataset, then exports to ONNX (int8) + a vocab TSV consumed by the
native C++ `CtcDecoder`.

> **Where to run this.** Colab Pro (A100, ~1–2 h on a 5% subset; ~12–24 h on the
> full corpus), Vast.ai 4090, or any local CUDA box ≥ 16 GB VRAM. The export &
> quantize steps run on CPU in minutes.

## Pipeline

```bash
pip install -r requirements.txt

# 1) Fine-tune (start with a small subset to validate end-to-end)
python train_wav2vec2_ctc.py \
    --base jonatasgrosman/wav2vec2-large-xlsr-53-arabic \
    --output ./out/wav2vec2-quran \
    --epochs 8 --batch 8 --lr 1e-4 \
    --subset 0.05                         # full run: drop --subset

# 2) Export → ONNX (fp32 + int8) + vocab.tsv
python export_onnx.py --ckpt ./out/wav2vec2-quran --out ./out/export

# 3) (Optional) Convert int8 ONNX → ORT format for mmap-friendly mobile loading
python convert_to_ort.py ./out/export/quran_ctc_int8.onnx

# 4) Ship to the app
cp ./out/export/quran_ctc_int8.onnx  ../flutter_patches/assets/models/
cp ./out/export/vocab.tsv            ../flutter_patches/assets/models/
```

## Files

| File | Purpose |
|---|---|
| `train_wav2vec2_ctc.py` | HF Trainer fine-tune on EveryAyah; builds a clean CTC vocab. |
| `export_onnx.py` | Trace + export to ONNX (dynamic time axis); dynamic int8 quantize; write `vocab.tsv`. |
| `convert_to_ort.py` | Optional ONNX → ORT format conversion. |

## Why this stack

- **CTC, not Whisper.** Frame-synchronous → genuine streaming, low decode
  latency, plays well with NNAPI/CoreML int8 kernels. The blueprint's "<300 ms"
  budget needs CTC; Whisper's 30 s autoregressive decode doesn't fit.
- **XLSR-53-Arabic base.** Already exposed to Arabic phonotactics — fine-tunes
  much faster (and to lower WER) than starting from `wav2vec2-base`.
- **Harakat stripped in training, kept for display.** The acoustic model learns
  the rasm; the alignment engine on the Dart side restores harakat for
  rendering via the original Uthmani text in SQLite. Loose-key matching is
  diacritic-insensitive by design.
- **Vocab as TSV, not vocab.json.** The C++ decoder is dependency-free —
  parsing `<id>\t<token>` is a single `std::getline`. No `nlohmann/json` needed.

## Honest caveats

- **Compute.** Full EveryAyah training is non-trivial — budget A100-hours. The
  `--subset` flag exists for end-to-end validation runs (loss should drop
  visibly within a few hundred steps; if it doesn't, something's miswired).
- **Vocab parity.** `export_onnx.py` writes `vocab.tsv` from the same
  `Wav2Vec2Processor` used at train time, so token IDs match. The C++ decoder
  loads it verbatim — never edit it by hand.
- **Input shape.** The exported model takes raw 16 kHz audio `[1, T_audio]` (no
  external feature extraction). The native orchestrator auto-detects this and
  skips its log-mel path; the model's own feature encoder runs on-device.
