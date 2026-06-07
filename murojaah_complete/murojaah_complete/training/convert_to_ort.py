#!/usr/bin/env python3
"""Convert ONNX → ORT format for mmap-friendly mobile loading.

ORT format is a serialized, optimized graph that ONNX Runtime Mobile
can mmap directly (no parser, no graph optimizations at session-create).
On low-end Android this trims cold-start by 100–400 ms.

Usage:
    python convert_to_ort.py ./out/export/quran_ctc_int8.onnx
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('onnx', help='input .onnx file')
    ap.add_argument('--optimization-style', default='Runtime',
                    choices=['Fixed', 'Runtime'])
    args = ap.parse_args()

    src = Path(args.onnx)
    if not src.exists():
        print(f'! not found: {src}', file=sys.stderr)
        return 1

    cmd = [
        sys.executable, '-m', 'onnxruntime.tools.convert_onnx_models_to_ort',
        str(src),
        '--optimization_style', args.optimization_style,
    ]
    print('·', ' '.join(cmd))
    rc = subprocess.call(cmd)
    if rc != 0:
        print('! conversion failed', file=sys.stderr)
        return rc

    ort_path = src.with_suffix('.ort')
    if ort_path.exists():
        print(f'✓ wrote {ort_path}  ({ort_path.stat().st_size // 1024} KB)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
