// murojaah_core.h — extern "C" ABI consumed by Dart via dart:ffi.
// The native core owns: ring buffer, resampler (→16k mono), VAD, log-mel,
// the ONNX Runtime session (NNAPI on Android, CoreML on iOS), and the CTC
// decoder.
#ifndef MUROJAAH_CORE_H
#define MUROJAAH_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Create an engine. model_path is mmap-ed by ONNX Runtime.
// A "vocab.tsv" must sit next to model_path (same directory).
// use_accel: 1 = enable NNAPI/CoreML EP (with CPU fallback), 0 = CPU only.
// Returns NULL on failure.
void* mj_create(const char* model_path, int use_accel);

void mj_destroy(void* handle);

// Push native-rate Int16 mono PCM from the audio callback.
// Safe to call from a real-time audio thread; never blocks on inference.
void mj_push_pcm(void* handle, const int16_t* pcm, int n_samples, int sample_rate);

// Run one inference hop over the current rolling window.
// Writes up to `cap` bytes of UTF-8 partial transcript into out_utf8 (NUL-term).
// out_conf receives the mean decode confidence (0..1).
// Returns 1 if speech was present (inference ran), 0 if VAD gated it (silence).
int mj_infer_hop(void* handle, char* out_utf8, int cap, float* out_conf);

#ifdef __cplusplus
}
#endif

#endif  // MUROJAAH_CORE_H
