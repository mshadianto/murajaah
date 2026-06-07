// murojaah_core.h — extern "C" ABI consumed by Dart via dart:ffi.
//
// v2 surface adds:
//   * mj_set_target  — install a per-ayah lexicon for biased beam decoding
//   * mj_mic_*       — native low-latency capture (Oboe on Android,
//                      AVAudioEngine on iOS); bypasses Dart on the audio hot path
#ifndef MUROJAAH_CORE_H
#define MUROJAAH_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Core engine ──────────────────────────────────────────────────────────────
// Create an engine. model_path is mmap-ed by ONNX Runtime.
// A "vocab.tsv" must sit next to model_path (same directory).
// use_accel: 1 = enable NNAPI/CoreML EP (with CPU fallback), 0 = CPU only.
// Returns NULL on failure.
void* mj_create(const char* model_path, int use_accel);

void mj_destroy(void* handle);

// Push native-rate Int16 mono PCM. Safe to call from a real-time audio thread;
// never blocks on inference.
void mj_push_pcm(void* handle, const int16_t* pcm, int n_samples, int sample_rate);

// Run one inference hop. Writes up to `cap` bytes of UTF-8 partial transcript
// into out_utf8 (NUL-terminated). out_conf receives mean decode confidence (0..1).
// Returns 1 if speech was present (inference ran), 0 if VAD gated it (silence).
int mj_infer_hop(void* handle, char* out_utf8, int cap, float* out_conf);

// ─── Lexicon-biased beam decoding ─────────────────────────────────────────────
// Install the active ayah's loose-keyed expected next words. text_utf8 is a
// space-separated UTF-8 string of harakat-stripped tokens (the Dart side
// produces this via ArabicNormalizer.looseKey on each upcoming word).
// beam_width <= 0 → switch back to greedy decoding.
// Passing NULL or "" with beam_width > 0 → beam search with no lexicon bias.
void mj_set_target(void* handle, const char* text_utf8, int beam_width);

// ─── Native mic capture (FFI-callable from Dart) ──────────────────────────────
// Create a mic session bound to a core handle. The session pushes Int16 PCM
// directly into mj_push_pcm from the OS audio thread (no Dart on hot path).
void* mj_mic_create(void* core_handle);

// Start capture. Caller must have obtained microphone permission first
// (use the `permission_handler` Flutter plugin or platform-specific APIs).
// Returns 1 on success.
int mj_mic_start(void* mic);

void mj_mic_stop(void* mic);
void mj_mic_destroy(void* mic);

#ifdef __cplusplus
}
#endif

#endif  // MUROJAAH_CORE_H
