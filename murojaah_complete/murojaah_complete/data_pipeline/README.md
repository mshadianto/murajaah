# Data Pipeline — Full Mushaf → SQLite asset

Build `assets/quran.db` (matches the app's schema 1:1) from a canonical Uthmani
text source, so the runtime app does **zero** normalization at startup.

## Use

```bash
# stdlib only — no pip install needed
python build_quran_db.py quran-uthmani.xml -o ../flutter_patches/assets/quran.db
```

Output:
```
✓ Built ../flutter_patches/assets/quran.db  (≈1500 KB, 6236 ayat)
```

Drop the resulting `quran.db` into `assets/` of the Flutter app and bundle it
via `pubspec.yaml` (see `flutter_patches/README.md`).

## Where to get the input

Two recommended sources (both public domain / free for non-commercial use):

1. **Tanzil — Uthmani XML** *(authoritative)*
   - <https://tanzil.net/download/> — choose "Quran Uthmani (with pause marks)" → XML.
   - Single file `quran-uthmani.xml`, ~1.5 MB.

2. **`fawazahmed0/quran-json`** *(GitHub, MIT)*
   - <https://github.com/fawazahmed0/quran-json> — Uthmani build.

Both are detected automatically by extension (`.xml` or `.json`).

## Guarantees

- **Schema match.** Tables, indexes, and column types are byte-identical to
  `QuranRepository._create()` in the Flutter app.
- **Normalization parity.** `normalizer.py` mirrors `ArabicNormalizer` in Dart;
  the self-check at the bottom of `normalizer.py` (`python normalizer.py`)
  catches any drift before you waste time building.
- **Sanity gate.** Per-surah ayah count is checked against the canonical
  metadata baked into the script; mismatched / truncated inputs fail loudly
  rather than producing a silently wrong DB.

## Files

| File | Purpose |
|---|---|
| `normalizer.py` | Python mirror of `ArabicNormalizer` (loose/strict keys). |
| `build_quran_db.py` | Parses Tanzil XML or Uthmani JSON → SQLite asset. |
