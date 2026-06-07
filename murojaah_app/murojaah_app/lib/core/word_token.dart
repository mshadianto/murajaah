/// A single word of the target ayah, tagged with its live recitation status.
enum WordStatus { correct, wrong, waiting }

class WordToken {
  final int position; // 0-based index within the ayah
  final String display; // Uthmani text (with harakat) for rendering
  WordStatus status;
  double confidence; // optional acoustic confidence (0..1)

  WordToken(
    this.position,
    this.display, {
    this.status = WordStatus.waiting,
    this.confidence = 0,
  });
}
