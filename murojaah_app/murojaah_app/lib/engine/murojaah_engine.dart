import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/alignment_service.dart';
import '../core/word_token.dart';
import '../stt/stt_engine.dart';

/// Wires an [SttEngine] (or manual text) → [AlignmentService] → [StatusStabilizer]
/// and exposes the live [tokens] + stats to the UI via [ChangeNotifier].
class MurojaahEngine extends ChangeNotifier {
  AlignmentService _aligner;
  final StatusStabilizer _stab = StatusStabilizer(holdHops: 2);
  List<WordToken> tokens;
  String recognized = '';

  SttEngine? _stt;
  StreamSubscription<String>? _sub;

  MurojaahEngine(List<String> words, {AlignmentConfig cfg = const AlignmentConfig()})
      : _aligner = AlignmentService(words, cfg: cfg),
        tokens = List.generate(words.length, (p) => WordToken(p, words[p]));

  /// Load a new ayah (or re-run with a new config for strict-mode toggling).
  void load(List<String> words, AlignmentConfig cfg) {
    detach();
    _aligner = AlignmentService(words, cfg: cfg);
    _stab.reset();
    recognized = '';
    tokens = List.generate(words.length, (p) => WordToken(p, words[p]));
    notifyListeners();
  }

  void _apply(String text) {
    recognized = text;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    tokens = _stab.commit(_aligner.align(words));
    notifyListeners();
  }

  /// Feed manual typed input (detaches any active STT).
  void setManual(String text) {
    detach();
    _apply(text);
  }

  /// Attach a streaming STT source and start it.
  Future<void> attach(SttEngine stt) async {
    await detach();
    _stt = stt;
    _stab.reset();
    _apply('');
    _sub = stt.transcript.listen(_apply);
    await stt.start();
    notifyListeners();
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    final s = _stt;
    _stt = null;
    if (s != null) await s.stop();
  }

  bool get isListening => _stt?.isRunning ?? false;

  void reset() {
    detach();
    _stab.reset();
    _apply('');
  }

  // ---- stats ----
  int get correct => tokens.where((t) => t.status == WordStatus.correct).length;
  int get wrong => tokens.where((t) => t.status == WordStatus.wrong).length;
  int get total => tokens.length;
  int get accuracy {
    final d = correct + wrong;
    return d == 0 ? 0 : ((correct / d) * 100).round();
  }

  int get progress => total == 0 ? 0 : ((correct / total) * 100).round();
  int get nextIndex => tokens.indexWhere((t) => t.status == WordStatus.waiting);

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
