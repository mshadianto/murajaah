// vad.cpp
#include "vad.h"

#include <cmath>

namespace mj {

void VAD::reset(float enter_db, float exit_db, int hangover) {
  enter_db_ = enter_db;
  exit_db_ = exit_db;
  hangover_ = hangover;
  active_ = false;
  below_count_ = 0;
}

bool VAD::update(const float* frame, size_t n) {
  if (n == 0) return active_;
  double acc = 0.0;
  for (size_t i = 0; i < n; ++i) acc += (double)frame[i] * frame[i];
  const float rms = (float)std::sqrt(acc / (double)n);
  // dBFS with a floor so log of zero stays finite.
  const float db = 20.0f * std::log10(std::max(rms, 1e-7f));

  if (db >= enter_db_) {
    active_ = true;
    below_count_ = 0;
  } else if (active_ && db < exit_db_) {
    if (++below_count_ >= hangover_) {
      active_ = false;
      below_count_ = 0;
    }
  } else {
    below_count_ = 0;
  }
  return active_;
}

}  // namespace mj
