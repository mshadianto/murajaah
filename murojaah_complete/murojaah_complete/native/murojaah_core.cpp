// murojaah_core.cpp — orchestrator wiring DSP + VAD + mel + ORT + CTC.
//
// Hot path on the audio thread (mj_push_pcm) does ONLY:
//   int16→float, resample, ring-buffer write, VAD frame update.
// Inference (FFT, mel, ORT.Run, CTC decode) runs on the Dart-side hop
// thread via mj_infer_hop — fully decoupled from capture.

#include "murojaah_core.h"

#include <onnxruntime_cxx_api.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "ctc_decode.h"
#include "dsp.h"
#include "ring_buffer.h"
#include "vad.h"

#if defined(__ANDROID__)
#include <onnxruntime/nnapi_provider_factory.h>
#elif defined(__APPLE__)
#include <onnxruntime/coreml_provider_factory.h>
#endif

namespace {

constexpr int kRing16kCapSamples = 16000 * 4;  // 4 s rolling window at 16 kHz
constexpr int kWindowSamples = 16000 * 3;      // 3 s inference window
constexpr int kVadFrame = 160;                 // 10 ms @ 16 kHz

struct Core {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "mj"};
  std::unique_ptr<Ort::Session> session;
  Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  mj::Resampler resampler;
  mj::VAD vad;
  mj::MelExtractor mel;
  mj::CtcDecoder decoder;
  mj::RingBuffer<float> ring{kRing16kCapSamples};

  // Scratch buffers — preallocated, reused every hop.
  std::vector<float> push_scratch;   // int16→float conversion on audio thread
  std::vector<float> resample_scratch;
  std::vector<float> window;         // last 3 s @ 16 kHz
  std::vector<float> mel_out;        // [T, 80]
  std::vector<int64_t> in_shape;     // [1, T, 80] (or [1, T_audio] for raw)
  std::vector<float> in_tensor;      // model input
  std::string in_name, out_name;
  bool raw_audio_input = false;      // true if model takes raw 16k samples

  std::mutex run_mu;                 // serialize mj_infer_hop callers
  std::atomic<bool> have_speech{false};
  int last_sr = 0;                   // last PCM sample rate seen on push thread
};

std::string dir_of(const std::string& path) {
  const auto p = path.find_last_of("/\\");
  return p == std::string::npos ? "." : path.substr(0, p);
}

}  // namespace

void* mj_create(const char* model_path, int use_accel) {
  try {
    auto c = std::make_unique<Core>();

    Ort::SessionOptions so;
    so.SetIntraOpNumThreads(2);
    so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    so.AddConfigEntry("session.use_ort_model_bytes_directly", "1");

#if defined(__ANDROID__)
    if (use_accel) {
      uint32_t flags = 0;  // CPU fallback for unsupported ops
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_Nnapi(so, flags));
    }
#elif defined(__APPLE__)
    if (use_accel) {
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(so, /*flags=*/0));
    }
#endif

    c->session = std::make_unique<Ort::Session>(c->env, model_path, so);

    // Discover I/O names + decide whether the model wants raw audio or log-mel.
    Ort::AllocatorWithDefaultOptions alloc;
    {
      auto name = c->session->GetInputNameAllocated(0, alloc);
      c->in_name = name.get();
      auto type_info = c->session->GetInputTypeInfo(0);
      auto shape = type_info.GetTensorTypeAndShapeInfo().GetShape();
      // Heuristic: wav2vec2-CTC input is [B, T_audio] (rank 2);
      //            log-mel models are [B, T, 80] (rank 3).
      c->raw_audio_input = (shape.size() == 2);
    }
    {
      auto name = c->session->GetOutputNameAllocated(0, alloc);
      c->out_name = name.get();
    }

    if (!c->decoder.load(dir_of(model_path) + "/vocab.tsv")) {
      // No vocab → core can still run encoder but cannot decode.
    }

    c->resampler.reset(16000.0f);  // re-init on first PCM push with real rate
    c->vad.reset(/*enter*/ -45.0f, /*exit*/ -55.0f, /*hangover*/ 12);
    c->push_scratch.reserve(48000);
    c->resample_scratch.reserve(16000);
    c->window.assign(kWindowSamples, 0.0f);
    c->mel_out.reserve(mj::MelExtractor::kNMels * 320);

    return c.release();
  } catch (const std::exception&) {
    return nullptr;
  }
}

void mj_destroy(void* handle) { delete static_cast<Core*>(handle); }

void mj_push_pcm(void* handle, const int16_t* pcm, int n, int sr) {
  auto* c = static_cast<Core*>(handle);
  if (!c || n <= 0 || sr <= 0) return;

  // (Re)initialize resampler if the rate changed.
  if (sr != c->last_sr) {
    c->resampler.reset((float)sr);
    c->last_sr = sr;
  }

  // int16 → float [-1, 1] into push_scratch.
  c->push_scratch.resize(n);
  constexpr float kInv = 1.0f / 32768.0f;
  for (int i = 0; i < n; ++i) c->push_scratch[i] = (float)pcm[i] * kInv;

  // Resample to 16 kHz.
  c->resample_scratch.clear();
  c->resampler.process(c->push_scratch.data(), c->push_scratch.size(), c->resample_scratch);
  if (c->resample_scratch.empty()) return;

  // Ring-buffer write (drops oldest when full).
  c->ring.write(c->resample_scratch.data(), c->resample_scratch.size());

  // VAD over the freshly produced 16k samples (10 ms frames).
  bool any_active = false;
  const float* p = c->resample_scratch.data();
  size_t remaining = c->resample_scratch.size();
  while (remaining >= (size_t)kVadFrame) {
    if (c->vad.update(p, kVadFrame)) any_active = true;
    p += kVadFrame;
    remaining -= kVadFrame;
  }
  if (c->vad.active() || any_active) c->have_speech.store(true);
}

int mj_infer_hop(void* handle, char* out, int cap, float* out_conf) {
  auto* c = static_cast<Core*>(handle);
  if (!c || cap <= 0) return 0;
  out[0] = '\0';
  if (out_conf) *out_conf = 0.0f;

  // VAD gate — silence skips inference entirely (battery win).
  if (!c->have_speech.exchange(false) && !c->vad.active()) return 0;

  std::lock_guard<std::mutex> lk(c->run_mu);

  // Snapshot the latest window from the ring.
  const size_t got = c->ring.peek_tail(c->window.data(), kWindowSamples);
  if (got < (size_t)mj::MelExtractor::kFrame) return 0;
  // If we got less than full window, zero-pad the leading part.
  if (got < (size_t)kWindowSamples) {
    std::memmove(c->window.data() + (kWindowSamples - got), c->window.data(), got * sizeof(float));
    std::memset(c->window.data(), 0, (kWindowSamples - got) * sizeof(float));
  }

  Ort::Value input{nullptr};
  if (c->raw_audio_input) {
    // wav2vec2-CTC takes raw 16 kHz audio: [1, T_audio].
    c->in_shape = {1, (int64_t)kWindowSamples};
    input = Ort::Value::CreateTensor<float>(c->mem, c->window.data(), kWindowSamples,
                                            c->in_shape.data(), c->in_shape.size());
  } else {
    // Log-mel model: [1, T, 80].
    const int T = c->mel.process(c->window.data(), kWindowSamples, c->mel_out);
    if (T <= 0) return 0;
    c->in_shape = {1, T, (int64_t)mj::MelExtractor::kNMels};
    input = Ort::Value::CreateTensor<float>(c->mem, c->mel_out.data(), c->mel_out.size(),
                                            c->in_shape.data(), c->in_shape.size());
  }

  const char* in_names[] = {c->in_name.c_str()};
  const char* out_names[] = {c->out_name.c_str()};
  std::vector<Ort::Value> outs;
  try {
    outs = c->session->Run(Ort::RunOptions{nullptr}, in_names, &input, 1, out_names, 1);
  } catch (const Ort::Exception&) {
    return 0;
  }
  if (outs.empty()) return 0;

  // Logits shape: [1, T, V].
  auto info = outs[0].GetTensorTypeAndShapeInfo();
  const auto shape = info.GetShape();
  if (shape.size() != 3) return 0;
  const int T = (int)shape[1];
  const int V = (int)shape[2];
  const float* logits = outs[0].GetTensorData<float>();

  float conf = 0.0f;
  std::string text = c->decoder.decode(logits, T, V, &conf);
  if (out_conf) *out_conf = conf;

  // Copy UTF-8 into out (NUL-terminate).
  const int n = std::min((int)text.size(), cap - 1);
  if (n > 0) std::memcpy(out, text.data(), (size_t)n);
  out[n] = '\0';
  return 1;
}
