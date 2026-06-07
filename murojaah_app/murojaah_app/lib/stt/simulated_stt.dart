import 'dart:async';

import '../core/arabic_normalizer.dart';
import '../data/quran_seed.dart';
import 'stt_engine.dart';

/// Drives a transcript from the target words, word by word, optionally
/// injecting one wrong word so the red highlighting is demonstrable.
/// No model or microphone required — this is the always-works demo path.
class SimulatedStt implements SttEngine {
  final List<String> targetWords;
  final Duration step;
  StreamController<String>? _ctrl;
  Timer? _timer;
  bool _running = false;

  SimulatedStt(this.targetWords, {this.step = const Duration(milliseconds: 620)});

  @override
  bool get isRunning => _running;

  @override
  Stream<String> get transcript =>
      (_ctrl ??= StreamController<String>.broadcast()).stream;

  @override
  Future<void> start() async {
    await stop();
    _ctrl ??= StreamController<String>.broadcast();
    _running = true;

    final n = targetWords.length;
    final now = DateTime.now();
    final errorAt = n > 3 ? 1 + (now.millisecondsSinceEpoch % (n - 2)) : -1;
    final doError = errorAt > 0 && (now.microsecond % 10) < 6;
    final acc = <String>[];
    var k = 0;

    _timer = Timer.periodic(step, (t) {
      if (k >= n) {
        t.cancel();
        _running = false;
        return;
      }
      if (doError && k == errorAt) {
        final tgt = ArabicNormalizer.looseKey(targetWords[k]);
        final wrong = kWrongPool.firstWhere(
          (w) => ArabicNormalizer.looseKey(w) != tgt,
          orElse: () => kWrongPool.first,
        );
        acc.add(wrong);
      } else {
        acc.add(targetWords[k]);
      }
      k++;
      _ctrl?.add(acc.join(' '));
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void dispose() {
    _timer?.cancel();
    _ctrl?.close();
    _ctrl = null;
  }
}
