// dsp.h — DSP primitives for the Murojaah core:
//   - Resampler   : arbitrary-rate → 16 kHz mono, windowed-sinc.
//   - FFT         : in-place radix-2 complex-to-complex.
//   - MelExtractor: 25 ms / 10 ms log-mel-80, matches torchaudio/librosa defaults.
#ifndef MJ_DSP_H
#define MJ_DSP_H

#include <complex>
#include <cstddef>
#include <vector>

namespace mj {

// ────────────────────────────────────────────────────────────────────────────
// Windowed-sinc resampler. One instance per audio stream; reset on rate change.
class Resampler {
 public:
  static constexpr int kTargetRate = 16000;
  static constexpr int kHalfTaps = 16;  // 32 taps total

  void reset(float in_rate);
  // Append n input samples; appends produced 16 kHz samples to out.
  void process(const float* in, size_t n, std::vector<float>& out);

 private:
  float in_rate_ = 16000.0f;
  float bw_ = 1.0f;            // bandlimit factor = min(1, 16k/in_rate)
  double step_ = 1.0;          // input samples per output sample
  double phase_ = 0.0;         // fractional read position in hist_
  std::vector<float> hist_;    // input history (grows; trimmed each call)
};

// ────────────────────────────────────────────────────────────────────────────
// In-place radix-2 FFT. Size must be a power of two.
void fft_radix2(std::complex<float>* x, size_t N);

// ────────────────────────────────────────────────────────────────────────────
// Log-mel spectrogram. Frame=25ms (400), Hop=10ms (160), N_FFT=512, N_MELS=80.
class MelExtractor {
 public:
  static constexpr int kFrame = 400;
  static constexpr int kHop = 160;
  static constexpr int kNfft = 512;
  static constexpr int kNMels = 80;

  MelExtractor();
  // Compute log-mel from 16 kHz mono samples.
  // Writes T*kNMels floats row-major into out (T = (n - kFrame)/kHop + 1).
  // Returns T (number of frames). out is resized.
  int process(const float* samples, size_t n, std::vector<float>& out);

 private:
  std::vector<float> hann_;                                  // Hann window
  std::vector<std::vector<std::pair<int, float>>> filters_;  // sparse mel
  std::vector<std::complex<float>> fft_buf_;                 // scratch
};

}  // namespace mj

#endif  // MJ_DSP_H
