// audio_capture_oboe.cpp — Android low-latency mic capture via Oboe.
//
// On-device audio callback pushes Int16 PCM straight into mj_push_pcm.
// Dart never sees the hot path: dart:ffi calls only mj_mic_{create,start,
// stop,destroy}, and the OS audio thread feeds the C++ core directly.
//
// Requires Oboe (NDK prefab `oboe::oboe` or vendored sources).

#include "murojaah_core.h"

#include <oboe/Oboe.h>

#include <atomic>
#include <memory>
#include <mutex>

namespace {

class MicSession : public oboe::AudioStreamDataCallback,
                   public oboe::AudioStreamErrorCallback {
 public:
  explicit MicSession(void* core) : core_(core) {}

  bool start() {
    oboe::AudioStreamBuilder b;
    b.setDirection(oboe::Direction::Input)
        .setPerformanceMode(oboe::PerformanceMode::LowLatency)
        .setSharingMode(oboe::SharingMode::Exclusive)
        .setFormat(oboe::AudioFormat::I16)
        .setChannelCount(oboe::ChannelCount::Mono)
        .setInputPreset(oboe::InputPreset::VoiceRecognition)
        .setDataCallback(this)
        .setErrorCallback(this);
    oboe::Result r = b.openStream(stream_);
    if (r != oboe::Result::OK) return false;
    sample_rate_ = stream_->getSampleRate();
    r = stream_->requestStart();
    return r == oboe::Result::OK;
  }

  void stop() {
    if (stream_) {
      stream_->requestStop();
      stream_->close();
      stream_.reset();
    }
  }

  // ── oboe callbacks ──────────────────────────────────────────────────────
  oboe::DataCallbackResult onAudioReady(oboe::AudioStream* s, void* data,
                                        int32_t n_frames) override {
    // Single-channel Int16 PCM; n_frames == n_samples for mono.
    if (core_) {
      mj_push_pcm(core_, static_cast<const int16_t*>(data), (int)n_frames,
                  (int)s->getSampleRate());
    }
    return oboe::DataCallbackResult::Continue;
  }
  bool onError(oboe::AudioStream*, oboe::Result) override { return false; }

 private:
  void* core_ = nullptr;
  std::shared_ptr<oboe::AudioStream> stream_;
  int32_t sample_rate_ = 0;
};

}  // namespace

extern "C" {

void* mj_mic_create(void* core_handle) {
  if (!core_handle) return nullptr;
  return new MicSession(core_handle);
}

int mj_mic_start(void* mic) {
  auto* m = static_cast<MicSession*>(mic);
  return (m && m->start()) ? 1 : 0;
}

void mj_mic_stop(void* mic) {
  auto* m = static_cast<MicSession*>(mic);
  if (m) m->stop();
}

void mj_mic_destroy(void* mic) { delete static_cast<MicSession*>(mic); }

}  // extern "C"
