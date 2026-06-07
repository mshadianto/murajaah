"""Python mirror of lib/core/arabic_normalizer.dart.

The normalization MUST stay byte-identical between Python (DB build) and
Dart (runtime) — otherwise the precomputed text_simple/text_strict in the
SQLite asset won't match what the alignment engine produces at runtime.
"""
from __future__ import annotations

import re

# Arabic combining marks + Qur'anic annotation signs.
_MARKS = re.compile(
    r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8'
    r'\u06EA-\u06ED\u08D3-\u08FF]'
)
_TATWEEL = re.compile('\u0640')
_INVISIBLE = re.compile(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]')

# Alef variants → ا
_ALEF_VARIANTS = re.compile(r'[\u0622\u0623\u0625\u0671\u0672\u0673]')


def _strip_marks(s: str) -> str:
    return _TATWEEL.sub('', _MARKS.sub('', s))


def _normalize_letters(s: str) -> str:
    s = _ALEF_VARIANTS.sub('\u0627', s)
    s = s.replace('\u0649', '\u064A')  # ى → ي
    s = s.replace('\u0624', '\u0648')  # ؤ → و
    s = s.replace('\u0626', '\u064A')  # ئ → ي
    s = s.replace('\u0629', '\u0647')  # ة → ه
    return s


def loose_key(w: str) -> str:
    """Forgiving key: no harakat, letter variants folded."""
    return _normalize_letters(_strip_marks(_INVISIBLE.sub('', w))).strip()


def strict_key(w: str) -> str:
    """Tajweed-precise key: harakat preserved, only invisible marks removed."""
    return _TATWEEL.sub('', _INVISIBLE.sub('', w)).strip()


if __name__ == '__main__':
    # Self-check parity with Dart.
    # Note: U+0670 (superscript alef) is a Mn-class mark — stripped in loose mode
    # to stay consistent with the cleaned training transcripts the STT model
    # learns from. Both target and recognized text normalize to the same rasm.
    samples = [
        ('بِسْمِ', 'بسم'),
        ('ٱللَّهِ', 'الله'),
        ('ٱلرَّحْمَٰنِ', 'الرحمن'),
        ('ٱلصِّرَٰطَ', 'الصرط'),
        ('وَلَا', 'ولا'),
        ('ٱلْعَٰلَمِينَ', 'العلمين'),
    ]
    ok = True
    for w, expected_loose in samples:
        got = loose_key(w)
        status = '✓' if got == expected_loose else '✗'
        ok &= (got == expected_loose)
        print(f'{status}  loose({w!r}) = {got!r}  (expected {expected_loose!r})')
    raise SystemExit(0 if ok else 1)
