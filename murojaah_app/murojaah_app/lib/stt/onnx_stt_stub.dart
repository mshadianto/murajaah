import 'dart:async';
import 'dart:typed_data';

import 'stt_engine.dart';

/// Web stub for OnnxStt.
///
/// Constructor succeeds (so caller code that instantiates can compile and
/// run), but [start] throws [UnsupportedError] because dart:ffi - the
/// dependency the native implementation needs - is unavailable on web.
///
/// The caller in `ui/murojaah_page.dart` already wraps construction + start
/// in try/catch and falls back to SimulatedStt / Manual input, so this stub
/// integrates transparently into the existing UX on web builds.
class OnnxStt implements SttEngine {
  OnnxStt({
    required this.modelPath,
    this.accel = true,
    this.hop = const Duration(milliseconds: 200),
  });

  final String modelPath;
  final bool accel;
  final Duration hop;

  @override
  bool get isRunning => false;

  @override
  Stream<String> get transcript => const Stream<String>.empty();

  @override
  Future<void> start() async {
    throw UnsupportedError(
      'OnnxStt requires dart:ffi (native runtime) and is unavailable on web. '
      'Callers should fall back to SimulatedStt for web builds.',
    );
  }

  /// No-op on web; present so caller code that compiles for both targets works.
  // ignore: avoid_positional_boolean_parameters
  void feedPcm(Int16List pcm, int sampleRate) {}

  @override
  Future<void> stop() async {}

  void dispose() {}
}