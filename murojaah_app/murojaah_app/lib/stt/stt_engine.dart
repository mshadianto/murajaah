/// A streaming speech-to-text source. Implementations emit a *cumulative*
/// partial transcript on [transcript] as recitation progresses.
///
/// Two implementations ship:
///  - [SimulatedStt] — drives a transcript from the target words (no model,
///    always works; used for the demo).
///  - [OnnxStt] — the real on-device path (ONNX Runtime + native C++ DSP).
abstract class SttEngine {
  /// Cumulative partial transcript (full text so far, space-separated words).
  Stream<String> get transcript;

  Future<void> start();
  Future<void> stop();
  bool get isRunning;
}
