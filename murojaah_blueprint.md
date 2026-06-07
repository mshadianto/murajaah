# Offline Real-Time Qur'an Memorization (Murojaah) Engine — Architecture Blueprint & Reference Code

**Framework decision: Flutter.** For this workload the deciding factor is the hot path: 16 kHz PCM → DSP → tensor → inference → alignment, 3–6 times per second, while painting per-word color changes at 60–120 fps. Flutter's `dart:ffi` gives near-zero-overhead, zero-copy interop with a native C++ DSP/inference core (no serialization across a bridge), and a single Skia/Impeller render pipeline keeps the live word-coloring jank-free. React Native's new architecture (JSI/TurboModules) can also do this, but Flutter FFI is the cleaner, more deterministic path for a C++ audio core. Everything below assumes Flutter + a thin native C++ layer.

---

## 0. System Architecture & Data Flow

```
┌──────────────────────────── UI Isolate (Flutter) ───────────────────────────┐
│  AyahView (RichText)  ◄── ValueListenable<List<WordToken>> ── DiffController  │
│        ▲ per-word color: green / red / gray                                  │
└────────┼─────────────────────────────────────────────────────────────────────┘
         │ SendPort (TransferableTypedData, zero-copy)
┌────────┴──────────────────── Inference Isolate (Dart) ───────────────────────┐
│  AlignmentService (semi-global DP)  ◄── partial transcript ── OnnxStt        │
└────────┬─────────────────────────────────────────────────────────────────────┘
         │ dart:ffi (Pointer<Float>, reused buffer — no per-frame malloc)
┌────────┴──────────────────────── Native C++ Core ────────────────────────────┐
│  RingBuffer ─► Resampler(→16k mono) ─► VAD gate ─► LogMel ─► ONNX Runtime     │
│                                                      (NNAPI / CoreML EP)      │
└────────┬─────────────────────────────────────────────────────────────────────┘
         │ Oboe (Android) / AVAudioEngine (iOS) low-latency capture callback
      🎤 Microphone
```

**Latency budget (target < 300 ms end-to-end).** Capture buffer ~20–30 ms → ring buffer/resample ~negligible → log-mel ~2–5 ms → CTC encoder inference on NNAPI/ANE ~40–120 ms (tiny/quantized) → greedy/forced-alignment decode ~5–15 ms → DP alignment on the tail window ~1–3 ms → SendPort to UI ~1 frame. We hit the budget by **running inference on a hop of ~160–240 ms over an overlapping window**, not on every 30 ms frame — the frame rate of *capture* and the frame rate of *inference* are decoupled.

---

## STEP 1 — Local Speech-to-Text Architecture

### 1.1 Why not "just Whisper"
Whisper is the accuracy leader and there are Quran-specific fine-tunes (`tarteel-ai/whisper-tiny-ar-quran`, `tarteel-ai/whisper-base-ar-quran`, Apache-2.0, trained on the Tarteel EveryAyah dataset). **But Whisper is not a streaming model** — its encoder expects a padded 30-second mel window and the decoder is autoregressive. Feeding it 1–2 s chunks degrades accuracy and adds decode latency, which is the opposite of what real-time word-by-word coloring needs.

### 1.2 Recommended primary model: a CTC acoustic model
Use a **frame-synchronous CTC encoder** (Wav2Vec2-CTC or a small Conformer-CTC) fine-tuned on Quran recitation, exported to **ONNX (int8)**. CTC is the right tool because:
- It is **streaming-native**: every encoder frame emits a posterior over the token vocabulary, so a growing partial transcript is available each hop — no autoregressive loop.
- It is small and fast and maps well onto NNAPI/ANE integer kernels.
- It pairs naturally with **forced alignment** (next section), which is the real unlock.

If you need something off-the-shelf *today* without training, **Vosk (Arabic small model)** is a genuinely streaming Kaldi decoder and is a reasonable bootstrap, though it is MSA-oriented and weaker on classical/Tajweed pronunciation than a Quran fine-tune.

**Keep Tarteel `whisper-tiny-ar-quran` as a secondary "verifier."** Run it offline on the completed ayah (or a 2–4 s rolling window every ~1 s) where latency is non-critical, to correct the live CTC stream and to score the final attempt. Two-tier: *fast CTC for live coloring, accurate Whisper for confirmation.*

### 1.3 The real unlock: closed-vocabulary forced alignment
You are not doing open-vocabulary dictation. The target ayah is **known**, and the entire corpus is a closed set of 6,236 ayahs. So you do not need the STT to *guess* the words — you need it to *confirm* the expected words and *flag* deviations. Two ways to exploit this:

1. **CTC forced alignment.** Convert the target ayah to its grapheme/token sequence, then use the CTC posterior matrix to align audio frames to that target sequence (Viterbi over the CTC trellis constrained to the target + blank). This yields per-word **start/end timestamps and confidence**, robustly, even when free decoding would have produced garbage. Words whose alignment confidence is high → green; low/absent → not-yet or wrong.
2. **Prefix-beam search with a token bias.** Run normal beam search but add a log-prob bonus to tokens that continue the expected next word(s). This keeps free-decoding flexibility (so genuine mistakes still surface as "wrong") while sharply improving accuracy on correct recitation.

Recommended: forced alignment for the green/gray decision (where am I in the ayah, is the next expected word being said correctly), free/biased decode in parallel to detect *substitutions* (wrong word) that forced alignment alone would smear.

### 1.4 Audio pipeline (capture → model input)
- **Capture**: platform low-latency audio — **Oboe (AAudio)** on Android, **AVAudioEngine** on iOS — at the device native rate (often 48 kHz), mono, Int16 (or Float32). Use small callback buffers (~10–20 ms).
- **Resample to 16 kHz mono PCM**: in C++ (polyphase / `libsamplerate` / `speexdsp`). Do *not* resample in Dart.
- **Ring buffer**: a single preallocated lock-free ring buffer holds the rolling audio; producer = audio callback, consumer = inference loop. No per-frame allocation, ever.
- **Frame & window**: accumulate 30 ms frames (480 samples @ 16 kHz). Maintain a rolling **window of ~1.5–3 s** with a **hop of ~160–240 ms**. The window (not the 30 ms frame) is what the model sees; the hop is how often you infer.
- **VAD gate**: WebRTC-VAD (or an energy + zero-crossing gate) decides whether the hop contains speech. **Silence → skip inference.** This is the biggest single battery/thermal saving and also prevents Whisper/CTC silence hallucination.
- **Features**: 80-bin **log-mel** spectrogram computed in C++ with NEON SIMD (window 25 ms, hop 10 ms), normalized per the model's training stats. This becomes the model input tensor.

---

## STEP 2 — Real-Time Text Alignment Algorithm

### 2.1 Normalization (diacritics handling)
Two keys per word, both precomputed at DB-build time and recomputed on the live transcript:
- **Loose key** — harakat/tashkeel and Quranic annotation marks stripped, letter variants normalized (all alef forms → ا, ى → ي, ؤ/ئ folded, optional ة → ه). Used for the default forgiving match.
- **Strict key** — harakat preserved (only invisible/bidi marks removed). Used for a Tajweed-precise mode where a wrong vowel counts as an error.

```dart
// arabic_normalizer.dart
class ArabicNormalizer {
  // Combining marks: Arabic harakat + Quranic annotation signs.
  static final RegExp _marks = RegExp(
    r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED\u08D3-\u08FF]',
  );
  static final RegExp _tatweel = RegExp('\u0640');
  static final RegExp _invisible = RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]');

  static String _stripMarks(String s) =>
      s.replaceAll(_marks, '').replaceAll(_tatweel, '');

  static String _normalizeLetters(String s) => s
      .replaceAll(RegExp(r'[\u0622\u0623\u0625\u0671\u0672\u0673]'), '\u0627') // آ أ إ ٱ → ا
      .replaceAll('\u0649', '\u064A')   // ى → ي
      .replaceAll('\u0624', '\u0648')   // ؤ → و
      .replaceAll('\u0626', '\u064A')   // ئ → ي
      .replaceAll('\u0629', '\u0647');  // ة → ه  (recitation-friendly; make optional)

  /// Forgiving key for matching.
  static String looseKey(String w) =>
      _normalizeLetters(_stripMarks(w.replaceAll(_invisible, ''))).trim();

  /// Tajweed-precise key (harakat preserved).
  static String strictKey(String w) =>
      _tatweel.hasMatch(w) || _invisible.hasMatch(w)
          ? w.replaceAll(_tatweel, '').replaceAll(_invisible, '').trim()
          : w.trim();
}
```

### 2.2 The algorithm: semi-global word alignment (free target ends)
We align the **partial recognized transcript** (short, growing) against the **full target ayah** (fixed). The right model is **semi-global / "glocal" alignment** — a Needleman–Wunsch DP where **gaps at the start *and* end of the target are free**. This makes the recognized window "snap" onto the correct region of the ayah (the streaming generalization the prompt's Smith-Waterman intuition is pointing at), while:
- target words matched by a hypothesis word → **correct** (green),
- target words matched against a *different* word → **wrong** (red, substitution),
- target words the reciter skipped past (gap *before* the recitation frontier) → **wrong** (missed),
- target words not yet reached (after the frontier) → **waiting** (gray).

Re-aligning the whole ayah each hop is cheap (most ayahs are short); for long ayahs, align only a **window around the frontier** (last matched index ± K) — see `alignWindowed`.

```dart
// alignment_service.dart
enum WordStatus { correct, wrong, waiting }

class WordToken {
  final int position;      // index within ayah
  final String display;    // Uthmani text (with harakat) for rendering
  WordStatus status;
  double confidence;       // optional acoustic confidence (0..1)
  WordToken(this.position, this.display,
      {this.status = WordStatus.waiting, this.confidence = 0});
}

class AlignmentConfig {
  final bool strict;              // strict = harakat-sensitive
  final double fuzzyThreshold;    // char-similarity to still count as a match
  final int matchScore, nearScore, mismatchScore, gapPenalty;
  const AlignmentConfig({
    this.strict = false,
    this.fuzzyThreshold = 0.82,
    this.matchScore = 2,
    this.nearScore = 1,
    this.mismatchScore = -2,
    this.gapPenalty = -1,
  });
}

class AlignmentService {
  final List<String> _targetKeys;     // normalized target words
  final List<String> _targetDisplay;  // Uthmani words for UI
  final AlignmentConfig cfg;

  AlignmentService(List<String> uthmaniWords, {this.cfg = const AlignmentConfig()})
      : _targetDisplay = List.unmodifiable(uthmaniWords),
        _targetKeys = List.unmodifiable(uthmaniWords.map(
            (w) => cfg_isStrict(uthmaniWords) // placeholder; see align()
                ? ArabicNormalizer.strictKey(w)
                : ArabicNormalizer.looseKey(w)));

  // (helper kept inline below in align(); constructor uses loose by default)
  static bool cfg_isStrict(_) => false;

  int _key(String a, String b) {
    if (a == b) return cfg.matchScore;
    return _similar(a, b) >= cfg.fuzzyThreshold ? cfg.nearScore : cfg.mismatchScore;
  }

  /// Normalized char-level similarity (1 - editDistance/maxLen).
  static double _similar(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final m = a.length, n = b.length;
    final prev = List<int>.generate(n + 1, (j) => j);
    final cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost]
            .reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= n; j++) prev[j] = cur[j];
    }
    final dist = prev[n];
    return 1.0 - dist / (m > n ? m : n);
  }

  /// Align the full partial transcript against the full ayah.
  /// [recognizedWords] are raw STT words (will be normalized here).
  List<WordToken> align(List<String> recognizedWords) {
    final hyp = recognizedWords
        .map((w) => cfg.strict
            ? ArabicNormalizer.strictKey(w)
            : ArabicNormalizer.looseKey(w))
        .where((w) => w.isNotEmpty)
        .toList();
    return _semiGlobal(hyp, 0, _targetKeys.length);
  }

  /// Window optimization for long ayahs: only align around [frontier].
  List<WordToken> alignWindowed(List<String> recognizedWords, int frontier,
      {int window = 12}) {
    final lo = (frontier - 2).clamp(0, _targetKeys.length);
    final hi = (frontier + window).clamp(0, _targetKeys.length);
    final tokens = _semiGlobal(
        recognizedWords
            .map((w) => cfg.strict
                ? ArabicNormalizer.strictKey(w)
                : ArabicNormalizer.looseKey(w))
            .where((w) => w.isNotEmpty)
            .toList(),
        lo, hi);
    // Everything before lo is already settled; everything after hi is waiting.
    return tokens;
  }

  List<WordToken> _semiGlobal(List<String> hyp, int tLo, int tHi) {
    final n = tHi - tLo;          // target slice length
    final m = hyp.length;         // hypothesis length
    final out = List<WordToken>.generate(_targetKeys.length,
        (p) => WordToken(p, _targetDisplay[p]));
    if (n == 0) return out;

    // DP grid (m+1) x (n+1). Free LEADING target gaps: dp[0][j] = 0.
    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
    final bt = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0)); // 0=diag,1=up,2=left
    for (var i = 1; i <= m; i++) {
      dp[i][0] = i * cfg.gapPenalty; // unmatched hypothesis = insertion (penalized)
      bt[i][0] = 1;
    }
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final s = _key(hyp[i - 1], _targetKeys[tLo + j - 1]);
        final diag = dp[i - 1][j - 1] + s;
        final up = dp[i - 1][j] + cfg.gapPenalty;   // hyp word, no target (insertion)
        final left = dp[i][j - 1] + cfg.gapPenalty; // target word skipped (deletion)
        var best = diag, dir = 0;
        if (up > best) { best = up; dir = 1; }
        if (left > best) { best = left; dir = 2; }
        dp[i][j] = best;
        bt[i][j] = dir;
      }
    }
    // Free TRAILING target gaps: pick best column in the last row.
    var jEnd = 0, bestVal = dp[m][0];
    for (var j = 1; j <= n; j++) {
      if (dp[m][j] >= bestVal) { bestVal = dp[m][j]; jEnd = j; }
    }
    // Frontier = last consumed target index; everything after stays "waiting".
    final frontierAbs = tLo + jEnd - 1;

    // Backtrack from (m, jEnd).
    var i = m, j = jEnd;
    while (i > 0 && j > 0) {
      final abs = tLo + j - 1;
      switch (bt[i][j]) {
        case 0: // diagonal: hyp[i-1] aligned to target[abs]
          final s = _key(hyp[i - 1], _targetKeys[abs]);
          out[abs].status =
              (s >= cfg.nearScore) ? WordStatus.correct : WordStatus.wrong;
          i--; j--;
          break;
        case 1: // up: extra spoken word (insertion) — no target consumed
          i--;
          break;
        case 2: // left: target word skipped by reciter
          out[abs].status =
              (abs <= frontierAbs) ? WordStatus.wrong : WordStatus.waiting;
          j--;
          break;
      }
    }
    // Remaining leading target columns (j>0, i==0) → not yet reached.
    while (j > 0) { out[tLo + j - 1].status = WordStatus.waiting; j--; }
    return out;
  }
}
```

> Note: in `align()` pass `cfg.strict` through to the precomputed keys. In production, precompute *both* loose and strict target keys once and select per `cfg.strict`; the inline `cfg_isStrict` placeholder above just defaults to loose to keep the snippet self-contained.

### 2.3 Anti-flicker stabilizer
STT partials jitter. Don't flip a word green/red on a single noisy hop. Require a status to be **stable for 2 consecutive hops** (or confidence above a floor) before committing — green/red latches, "waiting" never blocks. This removes 90% of perceived flicker for a few lines of code.

```dart
class StatusStabilizer {
  final int holdHops;
  final _pending = <int, (WordStatus, int)>{}; // pos -> (candidate, count)
  final _committed = <int, WordStatus>{};
  StatusStabilizer({this.holdHops = 2});

  List<WordToken> commit(List<WordToken> fresh) {
    for (final t in fresh) {
      if (t.status == WordStatus.waiting) continue; // never latch waiting
      final p = _pending[t.position];
      if (p != null && p.$1 == t.status) {
        final c = p.$2 + 1;
        if (c >= holdHops) _committed[t.position] = t.status;
        _pending[t.position] = (t.status, c);
      } else {
        _pending[t.position] = (t.status, 1);
      }
    }
    for (final t in fresh) {
      final c = _committed[t.position];
      if (c != null && t.status != WordStatus.waiting) t.status = c;
    }
    return fresh;
  }
}
```

---

## STEP 3 — Full Implementation Code

### 3.1 SQLite schema

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE surahs (
  id            INTEGER PRIMARY KEY,          -- 1..114
  name_ar       TEXT    NOT NULL,
  name_en       TEXT,
  ayah_count    INTEGER NOT NULL,
  revelation    TEXT CHECK (revelation IN ('meccan','medinan'))
);

CREATE TABLE ayahs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  surah_id      INTEGER NOT NULL REFERENCES surahs(id),
  ayah_number   INTEGER NOT NULL,             -- within surah
  text_uthmani  TEXT    NOT NULL,             -- full diacritized Uthmani script (display)
  text_simple   TEXT    NOT NULL,             -- harakat-stripped, letter-normalized (loose)
  word_count    INTEGER NOT NULL,
  juz           INTEGER,
  page          INTEGER,
  UNIQUE (surah_id, ayah_number)
);
CREATE INDEX idx_ayahs_surah ON ayahs(surah_id, ayah_number);

CREATE TABLE words (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ayah_id       INTEGER NOT NULL REFERENCES ayahs(id),
  position      INTEGER NOT NULL,             -- 0-based index in ayah
  text_uthmani  TEXT    NOT NULL,             -- word with harakat (display)
  text_simple   TEXT    NOT NULL,             -- loose key (no harakat, normalized)
  text_strict   TEXT    NOT NULL,             -- strict key (harakat preserved)
  phonemes      TEXT,                         -- optional: space-sep phoneme seq for forced alignment
  UNIQUE (ayah_id, position)
);
CREATE INDEX idx_words_ayah ON words(ayah_id, position);
```

Build the DB once in an **offline ETL** (Python) from a verified Uthmani source, computing `text_simple`/`text_strict` with the *same* normalization rules as `ArabicNormalizer`, and ship it as a read-only asset. Never normalize the whole corpus at runtime.

```dart
// quran_repository.dart  (sqflite)
class QuranRepository {
  final Database db;
  QuranRepository(this.db);

  Future<List<WordRow>> wordsForAyah(int surah, int ayah) async {
    final rows = await db.rawQuery('''
      SELECT w.position, w.text_uthmani, w.text_simple, w.text_strict
      FROM words w
      JOIN ayahs a ON a.id = w.ayah_id
      WHERE a.surah_id = ? AND a.ayah_number = ?
      ORDER BY w.position ASC
    ''', [surah, ayah]);
    return rows.map(WordRow.fromMap).toList();
  }
}

class WordRow {
  final int position;
  final String uthmani, simple, strict;
  WordRow(this.position, this.uthmani, this.simple, this.strict);
  factory WordRow.fromMap(Map<String, Object?> m) => WordRow(
        m['position'] as int,
        m['text_uthmani'] as String,
        m['text_simple'] as String,
        m['text_strict'] as String,
      );
}
```

### 3.2 Native C++ core (DSP + ONNX) and the FFI binding

**Header (C++ side, exposed via FFI).** The native core owns the ring buffer, resampler, VAD, log-mel and the ONNX session. Dart only pushes raw PCM and pulls back a transcript + per-frame confidence. Buffers are allocated **once**.

```cpp
// murojaah_core.h  — extern "C" ABI for dart:ffi
#ifdef __cplusplus
extern "C" {
#endif

// Returns an opaque handle. model_path is mmap-ed by ONNX Runtime.
void*  mj_create(const char* model_path, int use_accel /*1=NNAPI/CoreML*/);
void   mj_destroy(void* h);

// Push native-rate Int16 mono PCM from the audio callback (lock-free enqueue).
void   mj_push_pcm(void* h, const int16_t* pcm, int n_samples, int sample_rate);

// Run one inference hop on the current rolling window.
// Writes up to *cap UTF-8 bytes of partial transcript into out_utf8.
// Returns 1 if speech was present (inference ran), 0 if VAD gated it (skipped).
int    mj_infer_hop(void* h, char* out_utf8, int cap, float* out_conf);

#ifdef __cplusplus
}
#endif
```

**Core (sketch — the parts that matter; `// TODO` marks model-specific glue).**

```cpp
// murojaah_core.cpp
#include "murojaah_core.h"
#include <onnxruntime_cxx_api.h>
#include <vector>
#include <atomic>
#include <cstring>

struct Core {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "mj"};
  Ort::Session session{nullptr};
  Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  // Preallocated, reused every hop — no per-frame malloc.
  std::vector<float> ring;        // 16k mono rolling window
  std::vector<float> mel;         // log-mel scratch
  std::vector<float> in_tensor;   // model input scratch
  size_t ring_head = 0;
  std::atomic<bool> have_speech{false};
};

void* mj_create(const char* model_path, int use_accel) {
  auto* c = new Core();
  Ort::SessionOptions so;
  so.SetIntraOpNumThreads(2);                 // cap threads → fewer big-core wakes
  so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
  so.AddConfigEntry("session.use_ort_model_bytes_directly", "1"); // mmap-friendly
#if defined(__ANDROID__)
  if (use_accel) {
    uint32_t flags = 0; // 0 keeps CPU fallback for unsupported ops
    Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_Nnapi(so, flags));
  }
#elif defined(__APPLE__)
  if (use_accel) {
    Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(
        so, /*COREML_FLAG_USE_CPU_AND_GPU or ANE*/ 0));
  }
#endif
  c->session = Ort::Session(c->env, model_path, so); // ORT mmaps the file
  c->ring.assign(16000 * 3, 0.f);     // 3 s window
  c->mel.reserve(80 * 300);
  c->in_tensor.reserve(80 * 300);
  return c;
}

void mj_destroy(void* h) { delete static_cast<Core*>(h); }

void mj_push_pcm(void* h, const int16_t* pcm, int n, int sr) {
  auto* c = static_cast<Core*>(h);
  // TODO: resample sr→16k (polyphase/libsamplerate), convert Int16→Float32 [-1,1],
  //       write into c->ring as a circular buffer (advance ring_head).
  // TODO: WebRTC-VAD over the new frames → c->have_speech.store(...)
}

int mj_infer_hop(void* h, char* out, int cap, float* out_conf) {
  auto* c = static_cast<Core*>(h);
  if (!c->have_speech.load()) { if (out_conf) *out_conf = 0; out[0] = 0; return 0; }

  // 1) log-mel over current window (NEON SIMD) → c->mel  (TODO)
  // 2) shape input tensor [1, 80, T] → c->in_tensor       (TODO)
  // 3) run encoder:
  //   int64_t dims[] = {1, 80, T};
  //   auto input = Ort::Value::CreateTensor<float>(c->mem, c->in_tensor.data(),
  //                   c->in_tensor.size(), dims, 3);
  //   const char* in_names[] = {"input"}; const char* out_names[] = {"logits"};
  //   auto outs = c->session.Run(Ort::RunOptions{}, in_names, &input, 1, out_names, 1);
  // 4) CTC greedy/forced-alignment decode → UTF-8 partial transcript + mean conf (TODO)
  // 5) strncpy into out (≤cap), set *out_conf.
  return 1;
}
```

> The DSP and CTC decode are intentionally `// TODO`: their exact shapes/vocab depend on the model you export. Everything around them — session creation with mmap + NNAPI/CoreML, the reused buffers, the VAD gate, the ABI — is the production scaffolding.

**Dart FFI binding.**

```dart
// stt_native.dart
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _CreateC = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _Create = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _PushC = Void Function(Pointer<Void>, Pointer<Int16>, Int32, Int32);
typedef _Push = void Function(Pointer<Void>, Pointer<Int16>, int, int);
typedef _InferC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Float>);
typedef _Infer = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Float>);

class SttNative {
  final DynamicLibrary _lib;
  late final _Create _create =
      _lib.lookupFunction<_CreateC, _Create>('mj_create');
  late final _Push _push = _lib.lookupFunction<_PushC, _Push>('mj_push_pcm');
  late final _Infer _infer = _lib.lookupFunction<_InferC, _Infer>('mj_infer_hop');

  late final Pointer<Void> _h;
  // Reused buffers (no per-call allocation in the hot path).
  final Pointer<Uint8> _out = malloc.allocate<Uint8>(2048);
  final Pointer<Float> _conf = malloc.allocate<Float>(1);
  late final Pointer<Int16> _pcmBuf = malloc.allocate<Int16>(48000); // 1 s @ 48k

  SttNative(this._lib, String modelPath, {bool accel = true}) {
    final p = modelPath.toNativeUtf8();
    _h = _create(p, accel ? 1 : 0);
    malloc.free(p);
  }

  void pushPcm(Int16List pcm, int sampleRate) {
    final n = pcm.length;
    _pcmBuf.asTypedList(n).setAll(0, pcm); // copy into reused native buffer
    _push(_h, _pcmBuf, n, sampleRate);
  }

  ({String text, double conf, bool ran}) inferHop() {
    final ran = _infer(_h, _out, 2048, _conf) == 1;
    final bytes = <int>[];
    for (var i = 0; i < 2048; i++) {
      final b = _out[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return (text: utf8.decode(bytes), conf: _conf[0], ran: ran);
  }
}
```

### 3.3 The orchestrator (Inference Isolate)

```dart
// murojaah_engine.dart
class MurojaahEngine {
  final SttNative stt;
  final AlignmentService aligner;
  final StatusStabilizer stabilizer = StatusStabilizer(holdHops: 2);
  final void Function(List<WordToken>) onUpdate; // posts to UI isolate
  final _hopMs = 200;
  bool _running = false;
  final _accum = <String>[]; // committed transcript words

  MurojaahEngine(this.stt, this.aligner, this.onUpdate);

  void onAudioChunk(Int16List pcm, int sr) => stt.pushPcm(pcm, sr); // from mic callback

  Future<void> start() async {
    _running = true;
    while (_running) {
      final r = stt.inferHop();
      if (r.ran && r.text.trim().isNotEmpty) {
        // Replace tail with latest partial (CTC partials are cumulative for the window).
        final words = r.text.trim().split(RegExp(r'\s+'));
        final tokens = aligner.align(words);          // or alignWindowed(words, frontier)
        for (final t in tokens) t.confidence = r.conf;
        onUpdate(stabilizer.commit(tokens));
      }
      await Future.delayed(Duration(milliseconds: _hopMs));
    }
  }

  void stop() => _running = false;
}
```

### 3.4 UI — per-word coloring

```dart
// ayah_view.dart
class AyahView extends StatelessWidget {
  final List<WordToken> tokens;
  const AyahView(this.tokens, {super.key});

  Color _c(WordStatus s) => switch (s) {
        WordStatus.correct => const Color(0xFF1B873F), // green
        WordStatus.wrong   => const Color(0xFFD92D20), // red
        WordStatus.waiting => const Color(0xFF98A2B3), // gray
      };

  @override
  Widget build(BuildContext context) => RichText(
        textDirection: TextDirection.rtl,
        text: TextSpan(
          style: const TextStyle(fontFamily: 'UthmanicHafs', fontSize: 30, height: 2.0),
          children: [
            for (final t in tokens)
              TextSpan(text: '${t.display} ', style: TextStyle(color: _c(t.status))),
          ],
        ),
      );
}
```

Drive it with a `ValueNotifier<List<WordToken>>` updated from the `onUpdate` callback (which arrives via `SendPort`), so only the `RichText` rebuilds — never the whole screen.

---

## STEP 4 — Memory, Battery & Thermal Optimization

The enemy is **continuous inference on mid-range SoCs**. Strategy: do less work, on the right silicon, off the UI thread, with no allocations.

**1. Memory-map the model (don't heap-copy it).**
- ONNX Runtime: create the session from the **file path** (as above) so the OS maps the weights as read-only, demand-paged, shared pages — not a heap copy. Use the `.ort` format and `session.use_ort_model_bytes_directly`. TFLite equivalent: `Interpreter(modelFile)` mmaps the FlatBuffer; avoid `fromBuffer` which copies.
- Quantize to **int8** (dynamic or static). A tiny CTC encoder int8 is ~10–25 MB and runs on integer DSP/NNAPI kernels — smaller working set, less memory bandwidth (the real power cost on mobile), faster.

**2. Hardware acceleration with graceful fallback.**
- Android: **NNAPI EP** (or QNN/XNNPACK). NNAPI delegates supported subgraphs to NPU/GPU/DSP; unsupported ops fall back to CPU — keep CPU fallback enabled so you never crash on an op gap.
- iOS: **CoreML EP**, targeting the **Apple Neural Engine**. First run *compiles* the CoreML model to a device-specific format (slow once) — so **pre-warm** the session with a dummy input on screen entry and cache the compiled artifact.
- Always **benchmark both EPs against CPU** on a target device; on some SoCs a well-tuned XNNPACK CPU path beats a half-delegated NNAPI graph.

**3. Duty-cycle inference (biggest win).**
- Decouple capture (30 ms frames) from inference (**hop ~160–240 ms** over an overlapping window). You are not required to infer 33×/s; 4–6×/s is plenty for word-level feedback and cuts compute ~5×.
- **VAD-gate every hop**: silence → skip the encoder entirely. During pauses between ayahs the model does ~zero work. This also kills silence hallucination.

**4. Keep the UI isolate allocation-free and never let GC touch the hot loop.**
- Run DSP + inference + alignment in a dedicated **background Isolate**; the UI isolate only receives results. Dart GC is per-isolate, so a collection in the inference isolate can't stall the frame on the UI isolate.
- Reuse preallocated `Int16List`/`Float32List` and `malloc`'d native pointers across calls (shown in `SttNative`). No `List`/`String` churn per hop.
- Send results to UI via `SendPort` using `TransferableTypedData` for the heavy arrays (zero-copy ownership transfer) and a small plain object for statuses.
- Native side: ring buffer + scratch buffers allocated once; **nothing is freed in steady state**; use NEON SIMD for mel/resample to finish faster and return the core to idle (race-to-sleep).

**5. Adaptive thermal governor.**
- Poll thermal state — Android `PowerManager.getCurrentThermalStatus()`, iOS `ProcessInfo.processInfo.thermalState`. On `warning/serious`: **increase the hop** (lower inference rate), drop to the int8-tiny model, or temporarily disable the Whisper verifier pass. On `critical`: pause and surface a gentle UI hint. Race-to-sleep + duty-cycling usually keeps you out of throttle entirely on mid-range hardware.

**6. Lifecycle hygiene.**
- Stop the mic and inference loop on pause/background; release native scratch buffers; you can drop the in-memory session but keep the **mmap'd path** for a fast cold reload. Use **Oboe/AVAudioEngine** low-latency capture so buffers stay small and the audio thread itself is cheap.

---

### Quick build order (ship the smallest useful slice first)
1. DB + `ArabicNormalizer` + `AlignmentService` with a **fake transcript** (typed input) → prove the green/red/gray UI end-to-end with zero ML risk.
2. Drop in **Vosk Arabic** (streaming, off-the-shelf) → first real live coloring.
3. Train/export the **Quran CTC** model to ONNX int8, wire the C++ core + FFI, add VAD + forced alignment.
4. Add the **Tarteel whisper-tiny** verifier pass and the thermal governor.

Step 1 alone is a demo-able product; everything after is accuracy and polish.
