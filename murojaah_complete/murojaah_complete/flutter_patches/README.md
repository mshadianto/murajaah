# Flutter Patches — integrating the full pipeline

Apply these on top of the `murojaah_app` project from the previous deliverable.

## File overlays

| Source | Destination | Action |
|---|---|---|
| `lib/data/quran_repository.dart` | `murojaah_app/lib/data/quran_repository.dart` | **Replace** — loads `assets/quran.db` if bundled, falls back to the seeded mini-mushaf. |
| `lib/stt/asset_loader.dart` | `murojaah_app/lib/stt/asset_loader.dart` | **New file** — copies the bundled `.onnx` + `vocab.tsv` to a real file path. |

## pubspec.yaml — additions

Append to the existing `dependencies:` block:

```yaml
  path_provider: ^2.1.4
```

Replace the commented-out `assets:` block with:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/quran.db                      # built by data_pipeline/build_quran_db.py
    - assets/models/quran_ctc_int8.onnx    # built by training/export_onnx.py
    - assets/models/vocab.tsv              # written alongside the .onnx
```

## murojaah_page.dart — one-method patch

Change two things:

1. Add the import at the top:

```dart
import '../stt/asset_loader.dart';
```

2. Replace the stub `_resolveModelPath` with:

```dart
Future<String> _resolveModelPath() => ModelAssetLoader.ensure();
```

(Drop the `throw 'model on-device belum dibundle';` line.)

That's it — once you place `assets/quran.db`, `assets/models/quran_ctc_int8.onnx`,
and `assets/models/vocab.tsv` into the project, the **Mic** button starts running
on-device CTC inference through `OnnxStt → native core → ONNX Runtime`.

## Final mic wiring

`OnnxStt.start()` still has a `// TODO` for the mic capture itself. Pick one:

### Option A — `record` package (simpler)

Add to `pubspec.yaml`:
```yaml
  record: ^5.1.2
  permission_handler: ^11.3.1
```

Then inside `OnnxStt.start()`, after `_create` succeeds, add:
```dart
final rec = AudioRecorder();
if (!await rec.hasPermission()) throw 'mic permission denied';
final pcmStream = await rec.startStream(const RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    numChannels: 1,
    sampleRate: 48000,
    autoGain: false,
    echoCancel: false));
_micSub = pcmStream.listen((bytes) =>
    feedPcm(bytes.buffer.asInt16List(), 48000));
```
…and stop the recorder in `stop()`.

### Option B — platform channel to Oboe / AVAudioEngine (lower latency)

For the absolute minimum latency, write a thin platform channel:
- Android: `Oboe` (AAudio) callback → JNI → `mj_push_pcm` directly (skips Dart on the audio hot path).
- iOS: `AVAudioEngine` tap → C bridging → `mj_push_pcm`.

This is the production path described in the blueprint. The `feedPcm` Dart
method becomes optional in that case — the native side is fed directly from
the OS audio callback.
