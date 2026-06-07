#!/usr/bin/env python3
"""Build assets/quran.db from a canonical Uthmani source.

Inputs supported (auto-detected by extension):
  * Tanzil XML  — quran-uthmani.xml from https://tanzil.net/download/
  * JSON        — fawazahmed0/quran-json or quran.com Uthmani export

Output schema matches lib/data/quran_repository.dart exactly so the app
can drop this file in as assets/quran.db with zero runtime normalization.

Usage:
    python build_quran_db.py quran-uthmani.xml -o ../flutter_patches/assets/quran.db
    python build_quran_db.py quran-uthmani.json -o ./quran.db
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET
from typing import Iterable, Tuple

from normalizer import loose_key, strict_key

# Canonical surah metadata (id, name_ar, name_latin, ayah_count).
# Used to populate the surahs table; ayah_count is also cross-checked against
# the input file as a sanity gate.
SURAH_META: list[tuple[int, str, str, int]] = [
    (1, "الفاتحة", "Al-Fatihah", 7),
    (2, "البقرة", "Al-Baqarah", 286),
    (3, "آل عمران", "Aal-Imran", 200),
    (4, "النساء", "An-Nisa", 176),
    (5, "المائدة", "Al-Maidah", 120),
    (6, "الأنعام", "Al-Anam", 165),
    (7, "الأعراف", "Al-Araf", 206),
    (8, "الأنفال", "Al-Anfal", 75),
    (9, "التوبة", "At-Tawbah", 129),
    (10, "يونس", "Yunus", 109),
    (11, "هود", "Hud", 123),
    (12, "يوسف", "Yusuf", 111),
    (13, "الرعد", "Ar-Rad", 43),
    (14, "إبراهيم", "Ibrahim", 52),
    (15, "الحجر", "Al-Hijr", 99),
    (16, "النحل", "An-Nahl", 128),
    (17, "الإسراء", "Al-Isra", 111),
    (18, "الكهف", "Al-Kahf", 110),
    (19, "مريم", "Maryam", 98),
    (20, "طه", "Ta-Ha", 135),
    (21, "الأنبياء", "Al-Anbiya", 112),
    (22, "الحج", "Al-Hajj", 78),
    (23, "المؤمنون", "Al-Muminun", 118),
    (24, "النور", "An-Nur", 64),
    (25, "الفرقان", "Al-Furqan", 77),
    (26, "الشعراء", "Ash-Shuara", 227),
    (27, "النمل", "An-Naml", 93),
    (28, "القصص", "Al-Qasas", 88),
    (29, "العنكبوت", "Al-Ankabut", 69),
    (30, "الروم", "Ar-Rum", 60),
    (31, "لقمان", "Luqman", 34),
    (32, "السجدة", "As-Sajdah", 30),
    (33, "الأحزاب", "Al-Ahzab", 73),
    (34, "سبأ", "Saba", 54),
    (35, "فاطر", "Fatir", 45),
    (36, "يس", "Ya-Sin", 83),
    (37, "الصافات", "As-Saffat", 182),
    (38, "ص", "Sad", 88),
    (39, "الزمر", "Az-Zumar", 75),
    (40, "غافر", "Ghafir", 85),
    (41, "فصلت", "Fussilat", 54),
    (42, "الشورى", "Ash-Shura", 53),
    (43, "الزخرف", "Az-Zukhruf", 89),
    (44, "الدخان", "Ad-Dukhan", 59),
    (45, "الجاثية", "Al-Jathiyah", 37),
    (46, "الأحقاف", "Al-Ahqaf", 35),
    (47, "محمد", "Muhammad", 38),
    (48, "الفتح", "Al-Fath", 29),
    (49, "الحجرات", "Al-Hujurat", 18),
    (50, "ق", "Qaf", 45),
    (51, "الذاريات", "Adh-Dhariyat", 60),
    (52, "الطور", "At-Tur", 49),
    (53, "النجم", "An-Najm", 62),
    (54, "القمر", "Al-Qamar", 55),
    (55, "الرحمن", "Ar-Rahman", 78),
    (56, "الواقعة", "Al-Waqiah", 96),
    (57, "الحديد", "Al-Hadid", 29),
    (58, "المجادلة", "Al-Mujadilah", 22),
    (59, "الحشر", "Al-Hashr", 24),
    (60, "الممتحنة", "Al-Mumtahanah", 13),
    (61, "الصف", "As-Saf", 14),
    (62, "الجمعة", "Al-Jumuah", 11),
    (63, "المنافقون", "Al-Munafiqun", 11),
    (64, "التغابن", "At-Taghabun", 18),
    (65, "الطلاق", "At-Talaq", 12),
    (66, "التحريم", "At-Tahrim", 12),
    (67, "الملك", "Al-Mulk", 30),
    (68, "القلم", "Al-Qalam", 52),
    (69, "الحاقة", "Al-Haqqah", 52),
    (70, "المعارج", "Al-Maarij", 44),
    (71, "نوح", "Nuh", 28),
    (72, "الجن", "Al-Jinn", 28),
    (73, "المزمل", "Al-Muzzammil", 20),
    (74, "المدثر", "Al-Muddaththir", 56),
    (75, "القيامة", "Al-Qiyamah", 40),
    (76, "الإنسان", "Al-Insan", 31),
    (77, "المرسلات", "Al-Mursalat", 50),
    (78, "النبأ", "An-Naba", 40),
    (79, "النازعات", "An-Naziat", 46),
    (80, "عبس", "Abasa", 42),
    (81, "التكوير", "At-Takwir", 29),
    (82, "الانفطار", "Al-Infitar", 19),
    (83, "المطففين", "Al-Mutaffifin", 36),
    (84, "الانشقاق", "Al-Inshiqaq", 25),
    (85, "البروج", "Al-Buruj", 22),
    (86, "الطارق", "At-Tariq", 17),
    (87, "الأعلى", "Al-Ala", 19),
    (88, "الغاشية", "Al-Ghashiyah", 26),
    (89, "الفجر", "Al-Fajr", 30),
    (90, "البلد", "Al-Balad", 20),
    (91, "الشمس", "Ash-Shams", 15),
    (92, "الليل", "Al-Layl", 21),
    (93, "الضحى", "Ad-Duha", 11),
    (94, "الشرح", "Ash-Sharh", 8),
    (95, "التين", "At-Tin", 8),
    (96, "العلق", "Al-Alaq", 19),
    (97, "القدر", "Al-Qadr", 5),
    (98, "البينة", "Al-Bayyinah", 8),
    (99, "الزلزلة", "Az-Zalzalah", 8),
    (100, "العاديات", "Al-Adiyat", 11),
    (101, "القارعة", "Al-Qariah", 11),
    (102, "التكاثر", "At-Takathur", 8),
    (103, "العصر", "Al-Asr", 3),
    (104, "الهمزة", "Al-Humazah", 9),
    (105, "الفيل", "Al-Fil", 5),
    (106, "قريش", "Quraysh", 4),
    (107, "الماعون", "Al-Maun", 7),
    (108, "الكوثر", "Al-Kawthar", 3),
    (109, "الكافرون", "Al-Kafirun", 6),
    (110, "النصر", "An-Nasr", 3),
    (111, "المسد", "Al-Masad", 5),
    (112, "الإخلاص", "Al-Ikhlas", 4),
    (113, "الفلق", "Al-Falaq", 5),
    (114, "الناس", "An-Nas", 6),
]


def parse_tanzil_xml(path: str) -> Iterable[Tuple[int, int, str]]:
    """Yield (surah, ayah, text) from Tanzil's quran-uthmani.xml."""
    tree = ET.parse(path)
    for sura in tree.getroot().findall('sura'):
        sid = int(sura.attrib['index'])
        for aya in sura.findall('aya'):
            aid = int(aya.attrib['index'])
            text = aya.attrib['text']
            yield sid, aid, text


def parse_json(path: str) -> Iterable[Tuple[int, int, str]]:
    """Yield (surah, ayah, text) from common JSON shapes.

    Accepts:
      - quran-json style: {"1": {"1": {"text": "..."}, ...}, ...}
      - flat list:       [{"chapter":1,"verse":1,"text":"..."}, ...]
      - quran.com style: {"verses":[{"verse_key":"1:1","text_uthmani":"..."}]}
    """
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    if isinstance(data, dict) and 'verses' in data:
        for v in data['verses']:
            key = v.get('verse_key') or v['key']
            s, a = key.split(':')
            yield int(s), int(a), v.get('text_uthmani') or v['text']
        return

    if isinstance(data, list):
        for v in data:
            s = int(v.get('chapter') or v['surah'])
            a = int(v.get('verse') or v['ayah'])
            yield s, a, v['text']
        return

    if isinstance(data, dict):
        for s_str, ayat in data.items():
            try:
                s = int(s_str)
            except ValueError:
                continue
            if isinstance(ayat, dict):
                for a_str, item in ayat.items():
                    a = int(a_str)
                    text = item['text'] if isinstance(item, dict) else item
                    yield s, a, text
            elif isinstance(ayat, list):
                for a, item in enumerate(ayat, 1):
                    text = item['text'] if isinstance(item, dict) else item
                    yield s, a, text
        return

    raise SystemExit('Unrecognized JSON shape; see comments in parse_json().')


def build_db(input_path: str, out_path: str) -> None:
    if out_path != ':memory:' and os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
    db.execute('PRAGMA foreign_keys = ON')
    cur = db.cursor()

    # Schema (must match QuranRepository._create exactly).
    cur.executescript('''
    CREATE TABLE surahs(
      id INTEGER PRIMARY KEY,
      name_ar TEXT NOT NULL,
      name_latin TEXT,
      ayah_count INTEGER NOT NULL
    );
    CREATE TABLE ayahs(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      surah_id INTEGER NOT NULL,
      ayah_number INTEGER NOT NULL,
      text_uthmani TEXT NOT NULL,
      text_simple TEXT NOT NULL,
      word_count INTEGER NOT NULL,
      UNIQUE(surah_id, ayah_number)
    );
    CREATE INDEX idx_ayahs_surah ON ayahs(surah_id, ayah_number);
    CREATE TABLE words(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ayah_id INTEGER NOT NULL,
      position INTEGER NOT NULL,
      text_uthmani TEXT NOT NULL,
      text_simple TEXT NOT NULL,
      text_strict TEXT NOT NULL,
      UNIQUE(ayah_id, position)
    );
    CREATE INDEX idx_words_ayah ON words(ayah_id, position);
    ''')

    # Surahs
    cur.executemany(
        'INSERT INTO surahs(id, name_ar, name_latin, ayah_count) VALUES (?,?,?,?)',
        SURAH_META,
    )

    # Pick parser
    ext = os.path.splitext(input_path)[1].lower()
    if ext == '.xml':
        records = parse_tanzil_xml(input_path)
    elif ext == '.json':
        records = parse_json(input_path)
    else:
        raise SystemExit(f'Unsupported input extension: {ext}')

    # Build by (surah, ayah).
    counts = {sid: 0 for sid, *_ in SURAH_META}
    word_token_re = re.compile(r'\s+')
    ayah_rows = []
    for sid, aid, text in records:
        if sid not in counts:
            raise SystemExit(f'Surah index out of range: {sid}')
        words = [w for w in word_token_re.split(text) if w]
        ayah_rows.append((sid, aid, text, ' '.join(loose_key(w) for w in words), len(words), words))
        counts[sid] += 1

    # Sanity: ayah counts must match canonical metadata.
    for sid, _ar, _lat, expected in SURAH_META:
        if counts[sid] != expected:
            raise SystemExit(
                f'Surah {sid}: got {counts[sid]} ayat, expected {expected}. '
                f'Input file is likely truncated or uses a non-Uthmani recension.'
            )

    # Insert ayahs and words.
    for sid, aid, uthmani, simple, n_words, words in ayah_rows:
        cur.execute(
            'INSERT INTO ayahs(surah_id, ayah_number, text_uthmani, text_simple, word_count) '
            'VALUES (?,?,?,?,?)',
            (sid, aid, uthmani, simple, n_words),
        )
        ayah_id = cur.lastrowid
        cur.executemany(
            'INSERT INTO words(ayah_id, position, text_uthmani, text_simple, text_strict) '
            'VALUES (?,?,?,?,?)',
            [
                (ayah_id, i, w, loose_key(w), strict_key(w))
                for i, w in enumerate(words)
            ],
        )

    db.commit()
    # Compact + analyze for tiny, fast asset.
    cur.execute('ANALYZE')
    db.commit()
    db.close()

    # VACUUM in a fresh connection so it can rebuild the file.
    db = sqlite3.connect(out_path)
    db.execute('VACUUM')
    db.close()

    size_kb = os.path.getsize(out_path) // 1024
    print(f'✓ Built {out_path}  ({size_kb} KB, {len(ayah_rows)} ayat)')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('input', help='Tanzil XML or Uthmani JSON file')
    ap.add_argument('-o', '--output', default='quran.db', help='output SQLite path')
    args = ap.parse_args()
    build_db(args.input, args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
