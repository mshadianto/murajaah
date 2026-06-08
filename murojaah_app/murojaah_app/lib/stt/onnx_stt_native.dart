import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'stt_engine.dart';

// FFI signatures — must match native/murojaah_core.h
typedef _CreateC = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _CreateD = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _PushC = Void Function(Pointer<Void>, Pointer<Int16>, Int32, Int32);
typedef _PushD = void Function(Pointer<Void>, Pointer<Int16>, int, int);
typedef _InferC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Float>);
typedef _InferD = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Float>);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

/// On-device streaming STT backed by the native C++ core (ONNX Runtime with
/// NNAPI/CoreML, log-mel DSP, VAD). Dart pushes native-rate PCM via [feedPcm];
/// a hop timer pulls decoded partial transcripts back out.
///
/// Constructing this opens `libmurojaah_core` — it throws if the native lib
/// or model isn't present yet, which the UI catches to nudge you to the README.
class OnnxStt implements SttEngine {
  final String modelPath;
  final bool accel;
  final Duration hop;

  late final DynamicLibrary _lib;
  late final _CreateD _create;
  late final _PushD _push;
  late final _InferD _infer;
  late final _DestroyD _destroy;
  Pointer<Void>? _handle;

  // Reused buffers — no per-frame allocation in the hot path.
  final Pointer<Uint8> _outBuf = malloc.allocate<Uint8>(4096);
  final Pointer<Float> _confBuf = malloc.allocate<Float>(1);
  Pointer<Int16> _pcmBuf = malloc.allocate<Int16>(48000); // 1 s @ 48 kHz

  final StreamController<String> _ctrl = StreamController<String>.broadcast();
  Timer? _hopTimer;
  bool _running = false;

  OnnxStt({
    required this.modelPath,
    this.accel = true,
    this.hop = const Duration(milliseconds: 200),
  }) {
    _lib = _open();
    _create = _lib.lookupFunction<_CreateC, _CreateD>('mj_create');
    _push = _lib.lookupFunction<_PushC, _PushD>('mj_push_pcm');
    _infer = _lib.lookupFunction<_InferC, _InferD>('mj_infer_hop');
    _destroy = _lib.lookupFunction<_DestroyC, _DestroyD>('mj_destroy');
  }

  DynamicLibrary _open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libmurojaah_core.so');
    // iOS: statically linked into the runner → symbols live in the process.
    return DynamicLibrary.process();
  }

  @override
  bool get isRunning => _running;

  @override
  Stream<String> get transcript => _ctrl.stream;

  @override
  Future<void> start() async {
    final p = modelPath.toNativeUtf8();
    _handle = _create(p, accel ? 1 : 0); // ORT mmaps the model file
    malloc.free(p);
    _running = true;

    // TODO: start low-latency mic capture (Oboe / AVAudioEngine via platform
    //       channel, or the `record` package's PCM stream) and forward each
    //       frame to feedPcm(). Example with `record`:
    //
    //   final rec = AudioRecorder();
    //   final stream = await rec.startStream(const RecordConfig(
    //       encoder: AudioEncoder.pcm16bits, numChannels: 1, sampleRate: 48000));
    //   _micSub = stream.listen((bytes) =>
    //       feedPcm(bytes.buffer.asInt16List(), 48000));

    _hopTimer = Timer.periodic(hop, (_) => _runHop());
  }

  /// Push native-rate Int16 mono PCM into the native ring buffer.
  void feedPcm(Int16List pcm, int sampleRate) {
    final h = _handle;
    if (h == null) return;
    final n = pcm.length;
    if (n > 48000) {
      malloc.free(_pcmBuf);
      _pcmBuf = malloc.allocate<Int16>(n);
    }
    _pcmBuf.asTypedList(n).setAll(0, pcm);
    _push(h, _pcmBuf, n, sampleRate);
  }

  void _runHop() {
    final h = _handle;
    if (h == null) return;
    final ran = _infer(h, _outBuf, 4096, _confBuf) == 1; // 0 = VAD gated (silence)
    if (!ran) return;
    final bytes = <int>[];
    for (var i = 0; i < 4096; i++) {
      final b = _outBuf[i];
      if (b == 0) break;
      bytes.add(b);
    }
    if (bytes.isEmpty) return;
    _ctrl.add(utf8.decode(bytes, allowMalformed: true));
  }

  @override
  Future<void> stop() async {
    _hopTimer?.cancel();
    _hopTimer = null;
    final h = _handle;
    _handle = null;
    if (h != null) _destroy(h);
    _running = false;
  }

  void dispose() {
    stop();
    malloc.free(_outBuf);
    malloc.free(_confBuf);
    malloc.free(_pcmBuf);
    _ctrl.close();
  }
}
