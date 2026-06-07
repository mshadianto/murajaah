#!/usr/bin/env python3
"""Export a trained Wav2Vec2-CTC checkpoint to ONNX and int8-quantize it.

Outputs (next to each other — both copied into assets/models/ on the device):
    quran_ctc.onnx           # fp32 ONNX, dynamic time axis
    quran_ctc_int8.onnx      # dynamic int8 quantization (~4x smaller, mobile-fast)
    vocab.tsv                # <id>\t<utf8_token>\n — consumed by C++ CtcDecoder

Usage:
    python export_onnx.py --ckpt ./out/wav2vec2-quran --out ./out/export
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import torch
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor


class CtcEncoder(torch.nn.Module):
    """Wraps Wav2Vec2ForCTC so it has a clean (input_values) → logits forward."""

    def __init__(self, model: Wav2Vec2ForCTC):
        super().__init__()
        self.model = model

    def forward(self, input_values: torch.Tensor) -> torch.Tensor:
        out = self.model(input_values=input_values).logits
        return out  # [B, T, V]


def write_vocab_tsv(processor: Wav2Vec2Processor, path: str) -> None:
    vocab = processor.tokenizer.get_vocab()  # {token: id}
    # Invert and sort by id so the file's line order doesn't matter to the C++
    # parser (it reads `<id>\t<token>`), but produces a clean diff.
    rows = sorted(((idx, tok) for tok, idx in vocab.items()), key=lambda r: r[0])
    with open(path, 'w', encoding='utf-8') as f:
        for idx, tok in rows:
            f.write(f'{idx}\t{tok}\n')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--ckpt', required=True, help='HuggingFace checkpoint dir')
    ap.add_argument('--out', default='./out/export')
    ap.add_argument('--opset', type=int, default=17)
    ap.add_argument('--no-quantize', action='store_true', help='skip int8 quantization')
    ap.add_argument('--dummy-seconds', type=float, default=2.0,
                    help='length of the dummy input used for tracing')
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    print(f'· loading {args.ckpt}')
    processor = Wav2Vec2Processor.from_pretrained(args.ckpt)
    model = Wav2Vec2ForCTC.from_pretrained(args.ckpt).eval()
    wrapped = CtcEncoder(model).eval()

    # Vocab → TSV consumed by the C++ decoder.
    vocab_path = os.path.join(args.out, 'vocab.tsv')
    write_vocab_tsv(processor, vocab_path)
    print(f'✓ Wrote vocab → {vocab_path}  ({len(processor.tokenizer.get_vocab())} tokens)')

    # Trace + export.
    sr = 16000
    dummy_len = int(args.dummy_seconds * sr)
    dummy = torch.zeros(1, dummy_len, dtype=torch.float32)

    fp32_path = os.path.join(args.out, 'quran_ctc.onnx')
    print(f'· exporting fp32 ONNX → {fp32_path}')
    torch.onnx.export(
        wrapped,
        dummy,
        fp32_path,
        input_names=['input_values'],
        output_names=['logits'],
        dynamic_axes={
            'input_values': {0: 'batch', 1: 'time_audio'},
            'logits':       {0: 'batch', 1: 'time_frames'},
        },
        opset_version=args.opset,
        do_constant_folding=True,
    )

    # Sanity-check the exported graph.
    try:
        import onnxruntime as ort
        sess = ort.InferenceSession(fp32_path, providers=['CPUExecutionProvider'])
        out = sess.run(None, {'input_values': dummy.numpy()})[0]
        print(f'  ✓ fp32 sanity run OK   logits shape = {out.shape}')
    except Exception as e:
        print(f'  ! onnxruntime sanity failed: {e}', file=sys.stderr)

    if args.no_quantize:
        return 0

    # Dynamic int8 quantization — best mobile-CPU/NNAPI footprint.
    int8_path = os.path.join(args.out, 'quran_ctc_int8.onnx')
    print(f'· int8 quantizing → {int8_path}')
    try:
        from onnxruntime.quantization import quantize_dynamic, QuantType
        quantize_dynamic(
            model_input=fp32_path,
            model_output=int8_path,
            weight_type=QuantType.QInt8,
            per_channel=True,
            reduce_range=True,
        )
        fp32_sz = os.path.getsize(fp32_path) // 1024
        int8_sz = os.path.getsize(int8_path) // 1024
        print(f'  ✓ fp32 = {fp32_sz} KB · int8 = {int8_sz} KB '
              f'({100 * int8_sz / max(1, fp32_sz):.0f}%)')
    except Exception as e:
        print(f'  ! quantization failed: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
