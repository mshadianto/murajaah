import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/arabic_normalizer.dart';
import 'quran_seed.dart';

class SurahMeta {
  final int id;
  final String ar;
  final String latin;
  final int ayahCount;
  const SurahMeta(this.id, this.ar, this.latin, this.ayahCount);
}

/// Local, offline Qur'an store. Schema mirrors the blueprint:
/// surahs · ayahs (uthmani + simple) · words (uthmani + simple + strict).
class QuranRepository {
  final Database db;
  QuranRepository(this.db);

  static Future<QuranRepository> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'quran.db');
    final db = await openDatabase(path, version: 1, onCreate: _create);
    return QuranRepository(db);
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE surahs(
        id INTEGER PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_latin TEXT,
        ayah_count INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE ayahs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        surah_id INTEGER NOT NULL,
        ayah_number INTEGER NOT NULL,
        text_uthmani TEXT NOT NULL,
        text_simple TEXT NOT NULL,
        word_count INTEGER NOT NULL,
        UNIQUE(surah_id, ayah_number)
      )''');
    await db.execute('CREATE INDEX idx_ayahs_surah ON ayahs(surah_id, ayah_number)');
    await db.execute('''
      CREATE TABLE words(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ayah_id INTEGER NOT NULL,
        position INTEGER NOT NULL,
        text_uthmani TEXT NOT NULL,
        text_simple TEXT NOT NULL,
        text_strict TEXT NOT NULL,
        UNIQUE(ayah_id, position)
      )''');
    await db.execute('CREATE INDEX idx_words_ayah ON words(ayah_id, position)');

    final sb = db.batch();
    for (final s in kQuranSeed) {
      sb.insert('surahs', {
        'id': s.id,
        'name_ar': s.ar,
        'name_latin': s.latin,
        'ayah_count': s.ayat.length,
      });
    }
    await sb.commit(noResult: true);

    for (final s in kQuranSeed) {
      for (var a = 0; a < s.ayat.length; a++) {
        final text = s.ayat[a];
        final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        final ayahId = await db.insert('ayahs', {
          'surah_id': s.id,
          'ayah_number': a + 1,
          'text_uthmani': text,
          'text_simple': words.map(ArabicNormalizer.looseKey).join(' '),
          'word_count': words.length,
        });
        final wb = db.batch();
        for (var i = 0; i < words.length; i++) {
          wb.insert('words', {
            'ayah_id': ayahId,
            'position': i,
            'text_uthmani': words[i],
            'text_simple': ArabicNormalizer.looseKey(words[i]),
            'text_strict': ArabicNormalizer.strictKey(words[i]),
          });
        }
        await wb.commit(noResult: true);
      }
    }
  }

  Future<List<SurahMeta>> surahs() async {
    final rows = await db.query('surahs', orderBy: 'id');
    return rows
        .map((m) => SurahMeta(m['id'] as int, m['name_ar'] as String,
            (m['name_latin'] as String?) ?? '', m['ayah_count'] as int))
        .toList();
  }

  Future<List<String>> ayahWords(int surahId, int ayahNumber) async {
    final rows = await db.rawQuery('''
      SELECT w.text_uthmani FROM words w
      JOIN ayahs a ON a.id = w.ayah_id
      WHERE a.surah_id = ? AND a.ayah_number = ?
      ORDER BY w.position ASC
    ''', [surahId, ayahNumber]);
    return rows.map((m) => m['text_uthmani'] as String).toList();
  }
}
