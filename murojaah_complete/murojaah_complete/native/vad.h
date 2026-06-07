// vad.h — energy-based Voice Activity Detector with hysteresis.
//
// Honest about the trade-off: this is simpler than WebRTC-VAD but
// drop-in replaceable. Swap for libfvad/webrtcvad for production-grade
// noise robustness. For Murojaah (close-mic, indoors) energy VAD is fine.
#ifndef MJ_VAD_H
#define MJ_VAD_H

#include <cstddef>

namespace mj {

class VAD {
 public:
  void reset(float enter_db = -45.0f, float exit_db = -55.0f, int hangover = 12);
  // Process a 10 ms frame of 16 kHz float audio.
  // Returns true if the stream is currently active (speech).
  bool update(const float* frame, size_t n);
  bool active() const { return active_; }

 private:
  float enter_db_ = -45.0f;
  float exit_db_ = -55.0f;
  int hangover_ = 12;
  bool active_ = false;
  int below_count_ = 0;
};

}  // namespace mj

#endif  // MJ_VAD_H
