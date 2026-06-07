import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'audio_capture.dart';
import 'stt_engine.dart';

/// On-device CTC STT engine bound to the native Murojaah core via dart:ffi.
///
/// v2 additions over the previous deliverable:
///   * `setTarget(...)`  — installs a lexicon for biased beam decode.
///   * Native mic       — uses [NativeMicCapture] (Oboe / AVAudioEngine) so
///                        no audio data crosses the Dart boundary on the hot
///                        path; Dart only polls inference hops via a Timer.
///
/// The caller is responsible for obtaining microphone permission before
/// [start] — see [NativeMicCapture] for the permission_handler snippet.
class OnnxStt implements SttEngine {
  final String _modelPath;
  final bool _useAccel;
  final int _hopMs;

  late final ffi.DynamicLibrary _lib;
  late final ffi.Pointer<ffi.Void> _handle;
  late final NativeMicCapture _mic;
  late final ffi.Pointer<ffi.Uint8> _outBuf;
  late final ffi.Pointer<ffi.Float> _confBuf;
  static const int _outCap = 4096;

  // FFI functions on the core.
  late final _Create _ffiCreate;
  late final _Push _ffiPush;
  late final _Infer _ffiInfer;
  late final _Destroy _ffiDestroy;
  late final _SetTarget _ffiSetTarget;

  StreamController<String>? _ctrl;
  Timer? _hopTimer;
  bool _started = false;
  String _lastEmit = '';

  OnnxStt(this._modelPath, {bool useAccel = true, int hopMs = 200})
      : _useAccel = useAccel,
        _hopMs = hopMs {
    _lib = _openLib();
    _resolveSymbols();

    final pPath = _modelPath.toNativeUtf8();
    _handle = _ffiCreate(pPath, _useAccel ? 1 : 0);
    calloc.free(pPath);
    if (_handle == ffi.nullptr) {
      throw StateError('mj_create failed — check model path + vocab.tsv');
    }

    _mic = NativeMicCapture(_lib, _handle);
    _outBuf = calloc<ffi.Uint8>(_outCap);
    _confBuf = calloc<ffi.Float>();
  }

  ffi.DynamicLibrary _openLib() {
    if (Platform.isAndroid) return ffi.DynamicLibrary.open('libmurojaah_core.so');
    if (Platform.isIOS || Platform.isMacOS) return ffi.DynamicLibrary.process();
    if (Platform.isLinux) return ffi.DynamicLibrary.open('libmurojaah_core.so');
    if (Platform.isWindows) return ffi.DynamicLibrary.open('murojaah_core.dll');
    throw UnsupportedError('Murojaah native core not built for this platform');
  }

  void _resolveSymbols() {
    _ffiCreate = _lib
        .lookup<ffi.NativeFunction<_CreateC>>('mj_create')
        .asFunction<_Create>();
    _ffiPush = _lib
        .lookup<ffi.NativeFunction<_PushC>>('mj_push_pcm')
        .asFunction<_Push>();
    _ffiInfer = _lib
        .lookup<ffi.NativeFunction<_InferC>>('mj_infer_hop')
        .asFunction<_Infer>();
    _ffiDestroy = _lib
        .lookup<ffi.NativeFunction<_DestroyC>>('mj_destroy')
        .asFunction<_Destroy>();
    _ffiSetTarget = _lib
        .lookup<ffi.NativeFunction<_SetTargetC>>('mj_set_target')
        .asFunction<_SetTarget>();
  }

  // ── SttEngine ─────────────────────────────────────────────────────────────
  @override
  Stream<String> get transcript {
    _ctrl ??= StreamController<String>.broadcast();
    return _ctrl!.stream;
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _ctrl ??= StreamController<String>.broadcast();
    final ok = await _mic.start();
    if (!ok) {
      throw StateError(
          'Mic start failed — check permission_handler grant and Oboe/AVAudioEngine setup');
    }
    _started = true;
    _lastEmit = '';
    _hopTimer = Timer.periodic(Duration(milliseconds: _hopMs), (_) => _hop());
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _hopTimer?.cancel();
    _hopTimer = null;
    await _mic.stop();
  }

  // ── New surface ────────────────────────────────────────────────────────────
  /// Install the active ayah's expected next words (loose-keyed, harakat-
  /// stripped — typically `ArabicNormalizer.looseKey` applied per word).
  /// Pass [beamWidth] > 0 to enable biased beam decoding; pass `[]` or
  /// [beamWidth] == 0 to fall back to greedy decode.
  void setTarget(List<String> upcomingLooseWords, {int beamWidth = 16}) {
    final cleaned =
        upcomingLooseWords.where((w) => w.isNotEmpty).join(' ');
    if (cleaned.isEmpty) {
      _ffiSetTarget(_handle, ffi.nullptr, beamWidth);
      return;
    }
    final p = cleaned.toNativeUtf8();
    _ffiSetTarget(_handle, p, beamWidth);
    calloc.free(p);
  }

  /// Drop back to greedy decode (no lexicon, no beam).
  void clearTarget() {
    _ffiSetTarget(_handle, ffi.nullptr, 0);
  }

  /// Direct PCM feed for tests / non-native capture paths. The native mic
  /// covers the production path; this is for the `record` package or unit
  /// tests that drive the engine from disk.
  void feedPcm(Int16List samples, int sampleRate) {
    final n = samples.length;
    if (n == 0) return;
    final p = calloc<ffi.Int16>(n);
    p.asTypedList(n).setAll(0, samples);
    _ffiPush(_handle, p, n, sampleRate);
    calloc.free(p);
  }

  // ── Internal ──────────────────────────────────────────────────────────────
  void _hop() {
    if (!_started) return;
    final ran = _ffiInfer(_handle, _outBuf, _outCap, _confBuf);
    if (ran != 1) return;
    final str = _outBuf.cast<Utf8>().toDartString();
    if (str.isEmpty || str == _lastEmit) return;
    _lastEmit = str;
    _ctrl?.add(str);
  }

  void dispose() {
    stop();
    _ctrl?.close();
    _ctrl = null;
    if (_outBuf != ffi.nullptr) calloc.free(_outBuf);
    if (_confBuf != ffi.nullptr) calloc.free(_confBuf);
    if (_handle != ffi.nullptr) _ffiDestroy(_handle);
  }
}

// ─── FFI typedefs ─────────────────────────────────────────────────────────────
typedef _CreateC = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>, ffi.Int32);
typedef _Create = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>, int);

typedef _PushC = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int16>, ffi.Int32, ffi.Int32);
typedef _Push = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int16>, int, int);

typedef _InferC = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Pointer<ffi.Float>);
typedef _Infer = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Float>);

typedef _DestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _Destroy = void Function(ffi.Pointer<ffi.Void>);

typedef _SetTargetC = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Int32);
typedef _SetTarget = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, int);
