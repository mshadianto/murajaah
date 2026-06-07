import 'arabic_normalizer.dart';
import 'word_token.dart';

class AlignmentConfig {
  final bool strict; // strict = harakat-sensitive
  final double fuzzyThreshold; // char-similarity to still count as a match
  final int matchScore, nearScore, mismatchScore, gapPenalty;

  const AlignmentConfig({
    this.strict = false,
    this.fuzzyThreshold = 0.82,
    this.matchScore = 2,
    this.nearScore = 1,
    this.mismatchScore = -2,
    this.gapPenalty = -1,
  });
}

/// Word-level semi-global alignment: aligns a growing partial transcript
/// against a fixed target ayah. Gaps at both ends of the target are free,
/// so the recognized window "snaps" onto the right region:
///  - matched word          → correct (green)
///  - substituted word       → wrong (red)
///  - skipped (before front.) → wrong (red)
///  - not yet reached         → waiting (gray)
class AlignmentService {
  final List<String> display; // Uthmani words for rendering
  final List<String> _keys; // normalized target words
  final AlignmentConfig cfg;

  AlignmentService._(this.display, this._keys, this.cfg);

  factory AlignmentService(
    List<String> uthmaniWords, {
    AlignmentConfig cfg = const AlignmentConfig(),
  }) {
    final keys = uthmaniWords
        .map((w) =>
            cfg.strict ? ArabicNormalizer.strictKey(w) : ArabicNormalizer.looseKey(w))
        .toList(growable: false);
    return AlignmentService._(
        List.unmodifiable(uthmaniWords), List.unmodifiable(keys), cfg);
  }

  int _score(String a, String b) {
    if (a == b) return cfg.matchScore;
    return _similar(a, b) >= cfg.fuzzyThreshold ? cfg.nearScore : cfg.mismatchScore;
  }

  /// Normalized char-level similarity (1 - editDistance/maxLen).
  static double _similar(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = cur[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    return 1.0 - prev[n] / (m > n ? m : n);
  }

  /// Align the full partial transcript against the full ayah.
  List<WordToken> align(List<String> recognizedWords) {
    final hyp = recognizedWords
        .map((w) =>
            cfg.strict ? ArabicNormalizer.strictKey(w) : ArabicNormalizer.looseKey(w))
        .where((w) => w.isNotEmpty)
        .toList();
    return _semiGlobal(hyp);
  }

  List<WordToken> _semiGlobal(List<String> hyp) {
    final n = _keys.length, m = hyp.length;
    final out = List<WordToken>.generate(
        n, (p) => WordToken(p, display[p], status: WordStatus.waiting));
    if (n == 0 || m == 0) return out;

    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
    final bt = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0)); // 0 diag,1 up,2 left
    for (var i = 1; i <= m; i++) {
      dp[i][0] = i * cfg.gapPenalty; // unmatched hypothesis = insertion
      bt[i][0] = 1;
    }

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final s = _score(hyp[i - 1], _keys[j - 1]);
        final diag = dp[i - 1][j - 1] + s;
        final up = dp[i - 1][j] + cfg.gapPenalty; // extra spoken word (insertion)
        final left = dp[i][j - 1] + cfg.gapPenalty; // target word skipped (deletion)
        var best = diag, dir = 0;
        if (up > best) {
          best = up;
          dir = 1;
        }
        if (left > best) {
          best = left;
          dir = 2;
        }
        dp[i][j] = best;
        bt[i][j] = dir;
      }
    }

    // Free trailing target gaps → pick best column in the last row.
    var jEnd = 0, bestVal = dp[m][0];
    for (var j = 1; j <= n; j++) {
      if (dp[m][j] >= bestVal) {
        bestVal = dp[m][j];
        jEnd = j;
      }
    }
    final frontier = jEnd - 1; // last consumed target index

    var i = m, j = jEnd;
    while (i > 0 && j > 0) {
      final abs = j - 1;
      switch (bt[i][j]) {
        case 0: // diagonal
          final s = _score(hyp[i - 1], _keys[abs]);
          out[abs].status = s >= cfg.nearScore ? WordStatus.correct : WordStatus.wrong;
          i--;
          j--;
          break;
        case 1: // insertion, no target consumed
          i--;
          break;
        default: // target word skipped
          out[abs].status = abs <= frontier ? WordStatus.wrong : WordStatus.waiting;
          j--;
      }
    }
    while (j > 0) {
      out[j - 1].status = WordStatus.waiting;
      j--;
    }
    return out;
  }
}

/// Anti-flicker: a word turns (and stays) green once it has been correct for
/// [holdHops] consecutive evaluations. Wrong/waiting are always taken fresh.
class StatusStabilizer {
  final int holdHops;
  final Map<int, int> _pending = {};
  final Set<int> _greens = {};

  StatusStabilizer({this.holdHops = 2});

  List<WordToken> commit(List<WordToken> fresh) {
    for (final t in fresh) {
      if (t.status == WordStatus.correct) {
        final c = (_pending[t.position] ?? 0) + 1;
        _pending[t.position] = c;
        if (c >= holdHops) _greens.add(t.position);
      }
    }
    for (final t in fresh) {
      if (_greens.contains(t.position)) t.status = WordStatus.correct;
    }
    return fresh;
  }

  void reset() {
    _pending.clear();
    _greens.clear();
  }
}
