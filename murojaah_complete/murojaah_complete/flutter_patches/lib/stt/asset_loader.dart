import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copies `assets/models/quran_ctc_int8.onnx` (+ `vocab.tsv`) into the app's
/// support directory and returns the absolute model path. ONNX Runtime mmaps
/// the model from disk, so we need a real file path, not bytes.
///
/// Throws if the asset isn't bundled — the UI catches this and shows a hint
/// pointing at the training README.
class ModelAssetLoader {
  static const String _modelAsset = 'assets/models/quran_ctc_int8.onnx';
  static const String _vocabAsset = 'assets/models/vocab.tsv';

  /// Ensures the model + vocab exist on disk. Returns the model path.
  static Future<String> ensure() async {
    final dir = await getApplicationSupportDirectory();
    final modelDir = Directory(p.join(dir.path, 'models'));
    if (!await modelDir.exists()) await modelDir.create(recursive: true);

    final modelPath = p.join(modelDir.path, 'quran_ctc_int8.onnx');
    final vocabPath = p.join(modelDir.path, 'vocab.tsv');

    if (!await File(modelPath).exists()) await _copyAsset(_modelAsset, modelPath);
    if (!await File(vocabPath).exists()) await _copyAsset(_vocabAsset, vocabPath);

    return modelPath;
  }

  static Future<void> _copyAsset(String asset, String dest) async {
    final ByteData data = await rootBundle.load(asset);
    final Uint8List bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(dest).writeAsBytes(bytes, flush: true);
  }
}
