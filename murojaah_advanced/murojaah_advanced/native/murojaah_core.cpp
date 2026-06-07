// murojaah_core.cpp — orchestrator wiring DSP + VAD + mel + ORT + CTC + beam.
//
// v2 changes vs the previous deliverable:
//   * Adds BeamDecoder + Lexicon for biased prefix-beam decoding.
//   * mj_set_target() installs a per-ayah lexicon; when active, mj_infer_hop
//     uses the beam decoder instead of the greedy fallback.
//   * Native mic capture (mj_mic_*) lives in audio_capture_oboe.cpp /
//     audio_capture.mm — they call mj_push_pcm directly on the OS audio thread.

#include "murojaah_core.h"

#include <onnxruntime_cxx_api.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "beam_decode.h"
#include "ctc_decode.h"
#include "dsp.h"
#include "lexicon.h"
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
  mj::CtcDecoder greedy;
  mj::BeamDecoder beam;
  mj::RingBuffer<float> ring{kRing16kCapSamples};

  // Lexicon for biased beam (atomic swap from set_target).
  std::shared_ptr<mj::Lexicon> lexicon;
  std::mutex lex_mu;
  int beam_width = 0;  // 0 = greedy

  // Scratch buffers — preallocated, reused every hop.
  std::vector<float> push_scratch;
  std::vector<float> resample_scratch;
  std::vector<float> window;
  std::vector<float> mel_out;
  std::vector<int64_t> in_shape;
  std::string in_name, out_name;
  bool raw_audio_input = false;

  std::mutex run_mu;
  std::atomic<bool> have_speech{false};
  int last_sr = 0;
};

std::string dir_of(const std::string& path) {
  const auto p = path.find_last_of("/\\");
  return p == std::string::npos ? "." : path.substr(0, p);
}

std::vector<std::string> split_ws(const std::string& s) {
  std::vector<std::string> out;
  std::istringstream iss(s);
  std::string w;
  while (iss >> w) out.push_back(w);
  return out;
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
      uint32_t flags = 0;
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_Nnapi(so, flags));
    }
#elif defined(__APPLE__)
    if (use_accel) {
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(so, /*flags=*/0));
    }
#endif

    c->session = std::make_unique<Ort::Session>(c->env, model_path, so);

    Ort::AllocatorWithDefaultOptions alloc;
    {
      auto name = c->session->GetInputNameAllocated(0, alloc);
      c->in_name = name.get();
      auto type_info = c->session->GetInputTypeInfo(0);
      auto shape = type_info.GetTensorTypeAndShapeInfo().GetShape();
      c->raw_audio_input = (shape.size() == 2);
    }
    {
      auto name = c->session->GetOutputNameAllocated(0, alloc);
      c->out_name = name.get();
    }

    const std::string vocab_path = dir_of(model_path) + "/vocab.tsv";
    c->greedy.load(vocab_path);
    c->beam.load_vocab(vocab_path);

    c->resampler.reset(16000.0f);
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

  if (sr != c->last_sr) {
    c->resampler.reset((float)sr);
    c->last_sr = sr;
  }

  c->push_scratch.resize(n);
  constexpr float kInv = 1.0f / 32768.0f;
  for (int i = 0; i < n; ++i) c->push_scratch[i] = (float)pcm[i] * kInv;

  c->resample_scratch.clear();
  c->resampler.process(c->push_scratch.data(), c->push_scratch.size(), c->resample_scratch);
  if (c->resample_scratch.empty()) return;

  c->ring.write(c->resample_scratch.data(), c->resample_scratch.size());

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

void mj_set_target(void* handle, const char* text_utf8, int beam_width) {
  auto* c = static_cast<Core*>(handle);
  if (!c) return;
  std::lock_guard<std::mutex> lk(c->lex_mu);
  if (beam_width <= 0) {
    c->lexicon.reset();
    c->beam_width = 0;
    return;
  }
  auto lex = std::make_shared<mj::Lexicon>();
  if (text_utf8 && *text_utf8) {
    lex->set_words(split_ws(text_utf8));
  }
  c->lexicon = std::move(lex);
  c->beam_width = beam_width;
}

int mj_infer_hop(void* handle, char* out, int cap, float* out_conf) {
  auto* c = static_cast<Core*>(handle);
  if (!c || cap <= 0) return 0;
  out[0] = '\0';
  if (out_conf) *out_conf = 0.0f;

  if (!c->have_speech.exchange(false) && !c->vad.active()) return 0;

  std::lock_guard<std::mutex> lk(c->run_mu);

  const size_t got = c->ring.peek_tail(c->window.data(), kWindowSamples);
  if (got < (size_t)mj::MelExtractor::kFrame) return 0;
  if (got < (size_t)kWindowSamples) {
    std::memmove(c->window.data() + (kWindowSamples - got), c->window.data(), got * sizeof(float));
    std::memset(c->window.data(), 0, (kWindowSamples - got) * sizeof(float));
  }

  Ort::Value input{nullptr};
  if (c->raw_audio_input) {
    c->in_shape = {1, (int64_t)kWindowSamples};
    input = Ort::Value::CreateTensor<float>(c->mem, c->window.data(), kWindowSamples,
                                            c->in_shape.data(), c->in_shape.size());
  } else {
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

  auto info = outs[0].GetTensorTypeAndShapeInfo();
  const auto shape = info.GetShape();
  if (shape.size() != 3) return 0;
  const int T = (int)shape[1];
  const int V = (int)shape[2];
  const float* logits = outs[0].GetTensorData<float>();

  // Pick decoder by mode (snapshot under lex_mu so the read is consistent).
  int beam_w;
  std::shared_ptr<mj::Lexicon> lex_snap;
  {
    std::lock_guard<std::mutex> g(c->lex_mu);
    beam_w = c->beam_width;
    lex_snap = c->lexicon;
  }

  float conf = 0.0f;
  std::string text;
  if (beam_w > 0) {
    mj::BeamConfig bcfg;
    bcfg.beam_width = beam_w;
    text = c->beam.decode(logits, T, V, lex_snap.get(), &conf, bcfg);
  } else {
    text = c->greedy.decode(logits, T, V, &conf);
  }
  if (out_conf) *out_conf = conf;

  const int n = std::min((int)text.size(), cap - 1);
  if (n > 0) std::memcpy(out, text.data(), (size_t)n);
  out[n] = '\0';
  return 1;
}
