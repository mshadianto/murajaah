/// Arabic text normalization for Qur'anic word matching.
///
/// Two keys per word:
///  - [looseKey]  — harakat + Qur'anic annotation marks stripped, letter
///    variants folded. Forgiving match (default).
///  - [strictKey] — harakat preserved (only invisible/bidi marks removed).
///    Tajweed-precise match.
class ArabicNormalizer {
  // Combining marks: Arabic harakat + Qur'anic annotation signs.
  static final RegExp _marks = RegExp(
    r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED\u08D3-\u08FF]',
  );
  static final RegExp _tatweel = RegExp('\u0640');
  static final RegExp _invisible = RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]');

  static String _stripMarks(String s) =>
      s.replaceAll(_marks, '').replaceAll(_tatweel, '');

  static String _normalizeLetters(String s) => s
      .replaceAll(RegExp(r'[\u0622\u0623\u0625\u0671\u0672\u0673]'), '\u0627') // آ أ إ ٱ → ا
      .replaceAll('\u0649', '\u064A') // ى → ي
      .replaceAll('\u0624', '\u0648') // ؤ → و
      .replaceAll('\u0626', '\u064A') // ئ → ي
      .replaceAll('\u0629', '\u0647'); // ة → ه

  /// Forgiving key for matching.
  static String looseKey(String w) =>
      _normalizeLetters(_stripMarks(w.replaceAll(_invisible, ''))).trim();

  /// Tajweed-precise key (harakat preserved).
  static String strictKey(String w) =>
      w.replaceAll(_tatweel, '').replaceAll(_invisible, '').trim();
}
