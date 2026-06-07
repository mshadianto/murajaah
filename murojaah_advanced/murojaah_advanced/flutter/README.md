# Flutter Integration — v2 (setTarget + native mic)

Two file overlays on top of the existing `murojaah_app/lib/stt/` directory,
plus a tiny patch to `MurojaahEngine` to push the lexicon on cursor advance.

## File overlays

| Source | Destination | Action |
|---|---|---|
| `lib/stt/onnx_stt.dart` | `murojaah_app/lib/stt/onnx_stt.dart` | **Replace** — adds `setTarget`, switches to native mic. |
| `lib/stt/audio_capture.dart` | `murojaah_app/lib/stt/audio_capture.dart` | **New file** — FFI binding for `mj_mic_*`. |

## pubspec.yaml — additions

```yaml
dependencies:
  permission_handler: ^11.3.1
```

(`ffi` and `path_provider` are already in v1 deps.)

## Engine patch — push lexicon on cursor advance

In `lib/engine/murojaah_engine.dart`, find where `_apply` updates the cursor
position. After applying a transcript update, push the next ~6 expected words
to the STT. The pattern:

```dart
// inside MurojaahEngine after _apply mutates state:
void _refreshLexicon() {
  if (_stt is! OnnxStt) return;       // only the native engine supports it
  const horizon = 6;
  final upcoming = <String>[];
  for (var i = _cursor; i < _words.length && upcoming.length < horizon; i++) {
    upcoming.add(ArabicNormalizer.looseKey(_words[i]));
  }
  (_stt as OnnxStt).setTarget(upcoming, beamWidth: 16);
}
```

Call `_refreshLexicon()`:
- once on `attach()` (initial lexicon for word 0),
- inside the stabilizer hook whenever the cursor advances by ≥ 1 word.

When the user moves to a new ayah, the existing `setWords()` path naturally
resets the cursor — refresh the lexicon there too. Costs essentially nothing
(one FFI call per cursor step), pays off in WER.

## Permission flow

```dart
import 'package:permission_handler/permission_handler.dart';

// before _engine.attach(_onnx)
final ok = await Permission.microphone.request().isGranted;
if (!ok) {
  // show "Akses mic ditolak" snackbar; bail out
  return;
}
await _engine.attach(_onnx);
```

The native mic side fails fast (`mj_mic_start` returns 0) if permission
isn't granted, so this guard isn't strictly required for safety — but a
proper denied-permission UX is much nicer than a thrown FFI exception.

## What the user sees

Before the patch — greedy decode, no bias:
- Free-form CTC transcript drifts when a phoneme is ambiguous.
- Word-level WER is dominated by phonetically-similar substitutions.

After the patch — beam + lexicon:
- Beams that look like the expected next word get bonused.
- Substitutions toward expected words dominate the lattice.
- Net effect: 25–40% relative WER drop on close-mic recitation (rough — your
  mileage depends on model quality and lexicon horizon).

## Files

| File | Purpose |
|---|---|
| `lib/stt/onnx_stt.dart` | v2 OnnxStt: adds `setTarget`, native mic via FFI, removes `record` dep. |
| `lib/stt/audio_capture.dart` | FFI wrapper for `mj_mic_create/start/stop/destroy`. |
