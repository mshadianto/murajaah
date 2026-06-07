# Drop your exported on-device CTC model here, e.g.
# quran_ctc_int8.onnx
#
# Then in pubspec.yaml uncomment:
#   assets:
#     - assets/models/quran_ctc_int8.onnx
#
# And implement _resolveModelPath() in lib/ui/murojaah_page.dart to copy the
# asset to a file path (ONNX Runtime mmaps from a path, not from bytes).
