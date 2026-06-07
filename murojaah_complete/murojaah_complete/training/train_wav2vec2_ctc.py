#!/usr/bin/env python3
"""Fine-tune Wav2Vec2 with CTC head on Tarteel EveryAyah for Qur'anic ASR.

Designed to run on a single GPU (Colab T4/A100, or local CUDA box). For full
production training, use multi-GPU and the full dataset; for a smoke test,
pass --subset 0.05 to train on 5% of EveryAyah in a few hours.

Usage:
    python train_wav2vec2_ctc.py \\
        --base jonatasgrosman/wav2vec2-large-xlsr-53-arabic \\
        --output ./out/wav2vec2-quran \\
        --epochs 8 --batch 8 --lr 1e-4

Output:
    ./out/wav2vec2-quran/        # HuggingFace checkpoint dir
        config.json
        pytorch_model.bin (or model.safetensors)
        preprocessor_config.json
        tokenizer_config.json
        vocab.json               # consumed by export_onnx.py
"""
from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Union

import numpy as np
import torch
from datasets import Audio, load_dataset
from transformers import (
    Trainer,
    TrainingArguments,
    Wav2Vec2CTCTokenizer,
    Wav2Vec2FeatureExtractor,
    Wav2Vec2ForCTC,
    Wav2Vec2Processor,
)

# ─── Arabic text cleaning for training transcripts ────────────────────────────
# Strip harakat — the acoustic model learns the rasm; harakat are derivable
# from context and pollute the CTC vocab. We restore display Uthmani later.
ARABIC_MARKS = re.compile(
    r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8'
    r'\u06EA-\u06ED\u08D3-\u08FF\u0640]'
)
ARABIC_INVISIBLE = re.compile(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]')
ARABIC_PUNCT = re.compile(r'[،؛؟!.,\-\u061B\u061F]')


def clean_arabic(text: str) -> str:
    text = ARABIC_INVISIBLE.sub('', text)
    text = ARABIC_MARKS.sub('', text)
    text = ARABIC_PUNCT.sub(' ', text)
    # Fold alef variants for a tighter CTC vocab.
    text = re.sub(r'[\u0622\u0623\u0625\u0671\u0672\u0673]', '\u0627', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text


# ─── CTC vocab building ───────────────────────────────────────────────────────
def build_vocab(transcripts: List[str], out_dir: str) -> str:
    chars = set()
    for t in transcripts:
        chars.update(clean_arabic(t))
    chars.discard(' ')
    # Standard Wav2Vec2-CTC convention: '|' is the word separator, '[UNK]' / '[PAD]' are specials.
    vocab = {'[PAD]': 0, '[UNK]': 1, '|': 2}
    for c in sorted(chars):
        vocab[c] = len(vocab)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, 'vocab.json')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(vocab, f, ensure_ascii=False, indent=2)
    print(f'✓ Wrote vocab ({len(vocab)} tokens) to {path}')
    return path


# ─── Data collator (CTC padding) ──────────────────────────────────────────────
@dataclass
class DataCollatorCTCWithPadding:
    processor: Wav2Vec2Processor
    padding: Union[bool, str] = True

    def __call__(self, features: List[Dict[str, Any]]) -> Dict[str, torch.Tensor]:
        input_features = [{'input_values': f['input_values']} for f in features]
        label_features = [{'input_ids': f['labels']} for f in features]

        batch = self.processor.pad(input_features, padding=self.padding, return_tensors='pt')
        with self.processor.as_target_processor():
            labels_batch = self.processor.pad(label_features, padding=self.padding, return_tensors='pt')

        labels = labels_batch['input_ids'].masked_fill(
            labels_batch.attention_mask.ne(1), -100
        )
        batch['labels'] = labels
        return batch


# ─── Metric (WER) ─────────────────────────────────────────────────────────────
def wer(refs: List[str], hyps: List[str]) -> float:
    import numpy as np
    total_d, total_n = 0, 0
    for r, h in zip(refs, hyps):
        rw, hw = r.split(), h.split()
        # Levenshtein over words
        dp = np.zeros((len(rw) + 1, len(hw) + 1), dtype=np.int32)
        for i in range(len(rw) + 1): dp[i][0] = i
        for j in range(len(hw) + 1): dp[0][j] = j
        for i in range(1, len(rw) + 1):
            for j in range(1, len(hw) + 1):
                cost = 0 if rw[i - 1] == hw[j - 1] else 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
        total_d += int(dp[len(rw)][len(hw)])
        total_n += len(rw)
    return total_d / max(1, total_n)


# ─── Main ─────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='jonatasgrosman/wav2vec2-large-xlsr-53-arabic',
                    help='Base pretrained encoder')
    ap.add_argument('--dataset', default='tarteel-ai/everyayah',
                    help='HuggingFace dataset id (Tarteel EveryAyah)')
    ap.add_argument('--output', default='./out/wav2vec2-quran')
    ap.add_argument('--epochs', type=int, default=8)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--lr', type=float, default=1e-4)
    ap.add_argument('--subset', type=float, default=1.0, help='fraction of train split (0..1)')
    ap.add_argument('--max-duration', type=float, default=20.0, help='drop ayat > N seconds')
    ap.add_argument('--seed', type=int, default=42)
    args = ap.parse_args()

    print(f'· loading dataset {args.dataset} …')
    ds = load_dataset(args.dataset)
    # Most HF Quran ASR datasets expose 'train' / 'test' / 'validation' splits;
    # accept whatever's there and synthesize a test split if missing.
    train_ds = ds.get('train') or ds[list(ds.keys())[0]]
    eval_ds = ds.get('test') or ds.get('validation')
    if eval_ds is None:
        split = train_ds.train_test_split(test_size=0.02, seed=args.seed)
        train_ds, eval_ds = split['train'], split['test']

    # Subsample if requested (smoke-test convenience).
    if 0 < args.subset < 1.0:
        n = int(len(train_ds) * args.subset)
        train_ds = train_ds.shuffle(seed=args.seed).select(range(n))
        print(f'· subset: {n} training samples ({args.subset*100:.1f}%)')

    # Detect text + audio columns.
    text_col = 'text' if 'text' in train_ds.column_names else 'transcription'
    audio_col = 'audio' if 'audio' in train_ds.column_names else 'speech'
    train_ds = train_ds.cast_column(audio_col, Audio(sampling_rate=16000))
    eval_ds = eval_ds.cast_column(audio_col, Audio(sampling_rate=16000))

    # Clean text + filter overly long clips.
    def _clean(ex):
        ex[text_col] = clean_arabic(ex[text_col])
        return ex
    train_ds = train_ds.map(_clean)
    eval_ds = eval_ds.map(_clean)
    train_ds = train_ds.filter(
        lambda ex: ex[audio_col]['array'].shape[0] / 16000.0 <= args.max_duration
    )

    # Build vocab from training transcripts.
    transcripts = [ex[text_col] for ex in train_ds]
    vocab_path = build_vocab(transcripts, args.output)

    tokenizer = Wav2Vec2CTCTokenizer(
        vocab_path, unk_token='[UNK]', pad_token='[PAD]', word_delimiter_token='|'
    )
    feat = Wav2Vec2FeatureExtractor(
        feature_size=1, sampling_rate=16000, padding_value=0.0,
        do_normalize=True, return_attention_mask=True,
    )
    processor = Wav2Vec2Processor(feature_extractor=feat, tokenizer=tokenizer)
    processor.save_pretrained(args.output)

    # Encode dataset.
    def _prep(batch):
        audio = batch[audio_col]
        batch['input_values'] = processor(
            audio['array'], sampling_rate=16000
        ).input_values[0]
        batch['labels'] = processor(text=batch[text_col]).input_ids
        return batch
    train_ds = train_ds.map(_prep, remove_columns=train_ds.column_names, num_proc=1)
    eval_ds = eval_ds.map(_prep, remove_columns=eval_ds.column_names, num_proc=1)

    model = Wav2Vec2ForCTC.from_pretrained(
        args.base,
        ctc_loss_reduction='mean',
        pad_token_id=processor.tokenizer.pad_token_id,
        vocab_size=len(processor.tokenizer),
        ignore_mismatched_sizes=True,
    )
    model.freeze_feature_encoder()

    training_args = TrainingArguments(
        output_dir=args.output,
        per_device_train_batch_size=args.batch,
        per_device_eval_batch_size=args.batch,
        gradient_accumulation_steps=2,
        num_train_epochs=args.epochs,
        learning_rate=args.lr,
        warmup_ratio=0.1,
        evaluation_strategy='epoch',
        save_strategy='epoch',
        logging_steps=50,
        fp16=torch.cuda.is_available(),
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model='eval_loss',
        greater_is_better=False,
        report_to=[],
        seed=args.seed,
    )

    def compute_metrics(pred):
        pred_ids = np.argmax(pred.predictions, axis=-1)
        pred.label_ids[pred.label_ids == -100] = processor.tokenizer.pad_token_id
        pred_str = processor.batch_decode(pred_ids)
        label_str = processor.batch_decode(pred.label_ids, group_tokens=False)
        return {'wer': wer(label_str, pred_str)}

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        data_collator=DataCollatorCTCWithPadding(processor=processor),
        tokenizer=processor.feature_extractor,
        compute_metrics=compute_metrics,
    )
    trainer.train()
    trainer.save_model(args.output)
    processor.save_pretrained(args.output)
    print(f'✓ Saved checkpoint to {args.output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
