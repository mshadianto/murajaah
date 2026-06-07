// murojaah_core.cpp
//
// Production scaffolding for the on-device STT core. The pieces marked TODO
// (resample, VAD, log-mel, CTC decode) are model-specific glue; everything
// around them — session creation with mmap + NNAPI/CoreML, reused buffers,
// the lock-free audio path — is production-shaped.
//
// Link against onnxruntime-mobile (see CMakeLists.txt / iOS notes in README).

#include "murojaah_core.h"

#include <onnxruntime_cxx_api.h>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#if defined(__ANDROID__)
#include <onnxruntime/nnapi_provider_factory.h>
#endif

namespace {

struct Core {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "mj"};
  Ort::Session session{nullptr};
  Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  // Preallocated, reused every hop — no per-frame malloc.
  std::vector<float> ring;      // 16k mono rolling window (3 s)
  std::vector<float> mel;       // log-mel scratch
  std::vector<float> in_tensor; // model input scratch
  size_t ring_head = 0;
  std::atomic<bool> have_speech{false};
};

} // namespace

void* mj_create(const char* model_path, int use_accel) {
  auto* c = new Core();

  Ort::SessionOptions so;
  so.SetIntraOpNumThreads(2); // cap threads → fewer big-core wakes
  so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
  so.AddConfigEntry("session.use_ort_model_bytes_directly", "1"); // mmap-friendly

#if defined(__ANDROID__)
  if (use_accel) {
    uint32_t flags = 0; // keep CPU fallback for unsupported ops
    Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_Nnapi(so, flags));
  }
#elif defined(__APPLE__)
  if (use_accel) {
    // CoreML EP (ANE/GPU). First run compiles the model (warm-up once).
    Ort::ThrowOnError(
        OrtSessionOptionsAppendExecutionProvider_CoreML(so, /*flags=*/0));
  }
#endif

  c->session = Ort::Session(c->env, model_path, so); // ORT mmaps the file
  c->ring.assign(16000 * 3, 0.0f);
  c->mel.reserve(80 * 300);
  c->in_tensor.reserve(80 * 300);
  return c;
}

void mj_destroy(void* handle) { delete static_cast<Core*>(handle); }

void mj_push_pcm(void* handle, const int16_t* pcm, int n, int sr) {
  auto* c = static_cast<Core*>(handle);
  (void)pcm; (void)n; (void)sr; (void)c;
  // TODO: resample sr → 16k (polyphase / libsamplerate), Int16 → Float32 [-1,1],
  //       write into c->ring as a circular buffer (advance ring_head).
  // TODO: WebRTC-VAD over the new frames → c->have_speech.store(...)
}

int mj_infer_hop(void* handle, char* out, int cap, float* out_conf) {
  auto* c = static_cast<Core*>(handle);
  if (!c->have_speech.load()) {
    if (out_conf) *out_conf = 0.0f;
    if (cap > 0) out[0] = '\0';
    return 0; // VAD gated → skip the encoder entirely (battery win)
  }

  // 1) log-mel over current window (NEON SIMD) → c->mel                  (TODO)
  // 2) shape input tensor [1, 80, T] → c->in_tensor                       (TODO)
  // 3) run encoder:
  //      int64_t dims[] = {1, 80, T};
  //      auto input = Ort::Value::CreateTensor<float>(c->mem, c->in_tensor.data(),
  //                       c->in_tensor.size(), dims, 3);
  //      const char* in_names[]  = {"input"};
  //      const char* out_names[] = {"logits"};
  //      auto outs = c->session.Run(Ort::RunOptions{}, in_names, &input, 1,
  //                                 out_names, 1);
  // 4) CTC greedy / forced-alignment decode → UTF-8 partial + mean conf   (TODO)
  // 5) write into `out` (≤cap, NUL-terminated), set *out_conf.

  if (cap > 0) out[0] = '\0';
  if (out_conf) *out_conf = 0.0f;
  return 1;
}
