// wav_reader.h — minimal RIFF/WAV reader for desktop test harness.
// Supports 16-bit PCM, mono or stereo (auto-downmixed to mono).
#ifndef MJ_WAV_READER_H
#define MJ_WAV_READER_H

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace mj {

struct WavFile {
  std::vector<int16_t> samples;  // mono int16 PCM
  int sample_rate = 0;
  int channels = 0;
};

inline bool read_wav(const std::string& path, WavFile& out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  auto cleanup = [&](bool ok) { std::fclose(f); return ok; };

  char riff[4], wave[4];
  uint32_t riff_size;
  if (std::fread(riff, 1, 4, f) != 4 || std::memcmp(riff, "RIFF", 4) != 0) return cleanup(false);
  if (std::fread(&riff_size, 4, 1, f) != 1) return cleanup(false);
  if (std::fread(wave, 1, 4, f) != 4 || std::memcmp(wave, "WAVE", 4) != 0) return cleanup(false);

  // Scan chunks until we have fmt + data.
  uint16_t fmt_code = 0, channels = 0, bits_per_sample = 0;
  uint32_t sample_rate = 0;
  std::vector<int16_t> data;

  while (true) {
    char id[4];
    uint32_t sz;
    if (std::fread(id, 1, 4, f) != 4) break;
    if (std::fread(&sz, 4, 1, f) != 1) break;

    if (std::memcmp(id, "fmt ", 4) == 0) {
      const long start = std::ftell(f);
      auto must = [](size_t got, size_t want) { if (got != want) return false; return true; };
      if (!must(std::fread(&fmt_code, 2, 1, f), 1)) return cleanup(false);
      if (!must(std::fread(&channels, 2, 1, f), 1)) return cleanup(false);
      if (!must(std::fread(&sample_rate, 4, 1, f), 1)) return cleanup(false);
      uint32_t byte_rate;
      uint16_t block_align;
      if (!must(std::fread(&byte_rate, 4, 1, f), 1)) return cleanup(false);
      if (!must(std::fread(&block_align, 2, 1, f), 1)) return cleanup(false);
      if (!must(std::fread(&bits_per_sample, 2, 1, f), 1)) return cleanup(false);
      std::fseek(f, start + (long)sz, SEEK_SET);
    } else if (std::memcmp(id, "data", 4) == 0) {
      if (fmt_code != 1 || bits_per_sample != 16) return cleanup(false);
      const size_t n_samples = sz / 2;  // 16-bit
      data.resize(n_samples);
      if (std::fread(data.data(), 2, n_samples, f) != n_samples) return cleanup(false);
      break;
    } else {
      // skip unknown chunk
      std::fseek(f, (long)sz, SEEK_CUR);
    }
  }

  if (data.empty() || channels == 0) return cleanup(false);

  // Downmix stereo → mono if needed.
  if (channels == 1) {
    out.samples = std::move(data);
  } else {
    out.samples.resize(data.size() / channels);
    for (size_t i = 0; i < out.samples.size(); ++i) {
      int32_t acc = 0;
      for (int c = 0; c < channels; ++c) acc += data[i * channels + c];
      out.samples[i] = (int16_t)(acc / channels);
    }
  }
  out.sample_rate = (int)sample_rate;
  out.channels = (int)channels;
  return cleanup(true);
}

}  // namespace mj

#endif  // MJ_WAV_READER_H
