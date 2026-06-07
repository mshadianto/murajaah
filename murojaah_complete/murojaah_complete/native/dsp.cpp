// dsp.cpp
#include "dsp.h"

#include <algorithm>
#include <cmath>

namespace mj {

namespace {
constexpr float kPi = 3.14159265358979323846f;

inline float windowed_sinc(float x, float bw) {
  // sinc(bw*x) * Hann(x / (K_HALF * 2))
  const float a = kPi * x * bw;
  const float s = (std::fabs(a) < 1e-7f) ? 1.0f : std::sin(a) / a;
  // Hann window over [-K_HALF, +K_HALF].
  const float n = x / (2.0f * Resampler::kHalfTaps);
  if (n <= -0.5f || n >= 0.5f) return 0.0f;
  const float w = 0.5f + 0.5f * std::cos(2.0f * kPi * n);
  return bw * s * w;
}

inline float hz_to_mel(float f) { return 2595.0f * std::log10(1.0f + f / 700.0f); }
inline float mel_to_hz(float m) { return 700.0f * (std::pow(10.0f, m / 2595.0f) - 1.0f); }
}  // namespace

// ─────────────────────────────────── Resampler ────────────────────────────────

void Resampler::reset(float in_rate) {
  in_rate_ = in_rate > 0 ? in_rate : (float)kTargetRate;
  bw_ = std::min(1.0f, (float)kTargetRate / in_rate_);
  step_ = (double)in_rate_ / (double)kTargetRate;
  phase_ = 0.0;
  hist_.assign(kHalfTaps, 0.0f);  // zero-pad start so leading samples can be filtered
}

void Resampler::process(const float* in, size_t n, std::vector<float>& out) {
  if (n == 0) return;
  // Identity fast path when rates match exactly.
  if (std::fabs(step_ - 1.0) < 1e-9 && std::fabs(bw_ - 1.0f) < 1e-6f) {
    out.insert(out.end(), in, in + n);
    return;
  }
  hist_.insert(hist_.end(), in, in + n);

  // Need lookahead of kHalfTaps samples beyond phase_ to evaluate the kernel.
  while (phase_ + kHalfTaps < (double)hist_.size()) {
    const int n0 = (int)std::floor(phase_);
    const double mu = phase_ - n0;
    float sum = 0.0f;
    for (int k = -kHalfTaps + 1; k <= kHalfTaps; ++k) {
      const int idx = n0 + k;
      if (idx < 0 || idx >= (int)hist_.size()) continue;
      sum += hist_[idx] * windowed_sinc((float)(mu - k), bw_);
    }
    out.push_back(sum);
    phase_ += step_;
  }

  // Trim consumed history; keep last kHalfTaps samples for next call.
  const int trim_to = (int)std::floor(phase_) - kHalfTaps;
  if (trim_to > 0) {
    hist_.erase(hist_.begin(), hist_.begin() + trim_to);
    phase_ -= trim_to;
  }
}

// ────────────────────────────────────── FFT ───────────────────────────────────

void fft_radix2(std::complex<float>* x, size_t N) {
  // bit-reverse permutation
  size_t j = 0;
  for (size_t i = 1; i < N; ++i) {
    size_t bit = N >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(x[i], x[j]);
  }
  // Cooley-Tukey butterflies
  for (size_t len = 2; len <= N; len <<= 1) {
    const float ang = -2.0f * kPi / (float)len;
    const std::complex<float> wlen(std::cos(ang), std::sin(ang));
    for (size_t i = 0; i < N; i += len) {
      std::complex<float> w(1.0f, 0.0f);
      const size_t half = len >> 1;
      for (size_t k = 0; k < half; ++k) {
        const auto u = x[i + k];
        const auto v = x[i + k + half] * w;
        x[i + k] = u + v;
        x[i + k + half] = u - v;
        w *= wlen;
      }
    }
  }
}

// ────────────────────────────────── MelExtractor ──────────────────────────────

MelExtractor::MelExtractor() {
  // Hann window (Wav2Vec2-CTC / torchaudio default is Hann for log-mel).
  hann_.resize(kFrame);
  for (int i = 0; i < kFrame; ++i) {
    hann_[i] = 0.5f - 0.5f * std::cos(2.0f * kPi * (float)i / (float)(kFrame - 1));
  }

  // Slaney-style mel filterbank — 80 triangular filters over [0, sr/2].
  const float sr = (float)Resampler::kTargetRate;
  const float fmax = sr / 2.0f;
  const float mel_max = hz_to_mel(fmax);
  // N_MELS+2 anchor points in mel space.
  std::vector<float> mel_pts(kNMels + 2);
  for (int i = 0; i < kNMels + 2; ++i) {
    mel_pts[i] = mel_max * (float)i / (float)(kNMels + 1);
  }
  // Convert to FFT bin indices (float).
  std::vector<float> bin_pts(kNMels + 2);
  for (int i = 0; i < kNMels + 2; ++i) {
    bin_pts[i] = mel_to_hz(mel_pts[i]) * kNfft / sr;
  }
  filters_.assign(kNMels, {});
  for (int m = 0; m < kNMels; ++m) {
    const float lo = bin_pts[m], ctr = bin_pts[m + 1], hi = bin_pts[m + 2];
    const int kstart = (int)std::floor(lo);
    const int kend = (int)std::ceil(hi);
    for (int k = kstart; k <= kend; ++k) {
      if (k < 0 || k > kNfft / 2) continue;
      float w = 0.0f;
      if (k >= lo && k <= ctr && ctr > lo) w = (k - lo) / (ctr - lo);
      else if (k >= ctr && k <= hi && hi > ctr) w = (hi - k) / (hi - ctr);
      if (w > 0) filters_[m].push_back({k, w});
    }
  }
  fft_buf_.assign(kNfft, {});
}

int MelExtractor::process(const float* samples, size_t n, std::vector<float>& out) {
  if ((int)n < kFrame) {
    out.clear();
    return 0;
  }
  const int T = (int)((n - kFrame) / kHop) + 1;
  out.assign((size_t)T * kNMels, 0.0f);

  for (int t = 0; t < T; ++t) {
    const float* fr = samples + t * kHop;
    // window + zero-pad into fft_buf_
    for (int i = 0; i < kNfft; ++i) fft_buf_[i] = {0.0f, 0.0f};
    for (int i = 0; i < kFrame; ++i) fft_buf_[i] = {fr[i] * hann_[i], 0.0f};

    fft_radix2(fft_buf_.data(), kNfft);

    // power spectrum (kNfft/2 + 1 bins)
    float power[kNfft / 2 + 1];
    for (int k = 0; k <= kNfft / 2; ++k) {
      const float re = fft_buf_[k].real();
      const float im = fft_buf_[k].imag();
      power[k] = re * re + im * im;
    }
    // mel projection + log (with floor to avoid log(0))
    constexpr float kEps = 1e-10f;
    float* row = out.data() + (size_t)t * kNMels;
    for (int m = 0; m < kNMels; ++m) {
      float e = 0.0f;
      for (const auto& kv : filters_[m]) e += power[kv.first] * kv.second;
      row[m] = std::log(std::max(e, kEps));
    }
  }
  return T;
}

}  // namespace mj
