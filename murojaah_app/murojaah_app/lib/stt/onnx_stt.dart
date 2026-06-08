/// Platform-conditional re-export of OnnxStt.
///
/// - On native platforms (mobile/desktop, `dart:io` available): real
///   implementation in `onnx_stt_native.dart`, backed by `dart:ffi` -> 
///   libmurojaah_core (ONNX Runtime + C++ DSP).
/// - On web (`dart:io` unavailable): stub in `onnx_stt_stub.dart` whose
///   constructor succeeds but `start()` throws UnsupportedError. The caller
///   in ui/murojaah_page.dart already wraps construction + start in try/catch
///   and shows a SnackBar guiding the user to Simulasi / Manual.
///
/// Conditional imports are resolved at compile time:
///   - dart2js (web build)        -> picks onnx_stt_stub.dart
///   - native (mobile/desktop)    -> picks onnx_stt_native.dart
library;

export 'onnx_stt_stub.dart'
    if (dart.library.io) 'onnx_stt_native.dart';