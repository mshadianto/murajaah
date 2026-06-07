import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// FFI binding around the native low-latency mic capture
/// (Oboe on Android / AVAudioEngine on iOS).
///
/// The native side calls `mj_push_pcm` directly from the OS audio thread —
/// Dart is **not** in the audio hot path. Dart only polls `mj_infer_hop` via
/// a periodic timer (handled by [OnnxStt]).
///
/// Permission: the caller must obtain microphone permission before [start].
/// Use the `permission_handler` package (or platform-equivalent):
///   ```dart
///   final ok = await Permission.microphone.request().isGranted;
///   if (!ok) return;
///   ```
class NativeMicCapture {
  final ffi.DynamicLibrary _lib;
  final ffi.Pointer<ffi.Void> _coreHandle;
  late final _MicCreate _create;
  late final _MicStart _start;
  late final _MicStop _stop;
  late final _MicDestroy _destroy;
  ffi.Pointer<ffi.Void> _mic = ffi.nullptr;

  NativeMicCapture(this._lib, this._coreHandle) {
    _create = _lib
        .lookup<ffi.NativeFunction<_MicCreateC>>('mj_mic_create')
        .asFunction<_MicCreate>();
    _start = _lib
        .lookup<ffi.NativeFunction<_MicStartC>>('mj_mic_start')
        .asFunction<_MicStart>();
    _stop = _lib
        .lookup<ffi.NativeFunction<_MicStopC>>('mj_mic_stop')
        .asFunction<_MicStop>();
    _destroy = _lib
        .lookup<ffi.NativeFunction<_MicDestroyC>>('mj_mic_destroy')
        .asFunction<_MicDestroy>();
  }

  /// Returns true once the OS audio thread is delivering frames.
  Future<bool> start() async {
    if (_mic != ffi.nullptr) return true;
    final m = _create(_coreHandle);
    if (m == ffi.nullptr) return false;
    final ok = _start(m);
    if (ok == 0) {
      _destroy(m);
      return false;
    }
    _mic = m;
    return true;
  }

  Future<void> stop() async {
    if (_mic == ffi.nullptr) return;
    _stop(_mic);
    _destroy(_mic);
    _mic = ffi.nullptr;
  }

  bool get isActive => _mic != ffi.nullptr;
}

// ─── FFI typedefs ─────────────────────────────────────────────────────────────
typedef _MicCreateC = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _MicCreate = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _MicStartC = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _MicStart = int Function(ffi.Pointer<ffi.Void>);

typedef _MicStopC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _MicStop = void Function(ffi.Pointer<ffi.Void>);

typedef _MicDestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _MicDestroy = void Function(ffi.Pointer<ffi.Void>);
