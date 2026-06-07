// main_test.cpp — desktop end-to-end smoke test for the Murojaah native core.
//
//   ./murojaah_test <model.onnx> <input.wav> [--target "expected ayah words..."]
//
// Streams the WAV through mj_push_pcm in real-time-sized chunks (32 ms),
// calls mj_infer_hop every 200 ms, prints incremental transcripts and
// final confidence. Useful for validating the C++ pipeline on a laptop
// before deploying to mobile.

#include "murojaah_core.h"
#include "wav_reader.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

static std::vector<std::string> split_ws(const std::string& s) {
  std::vector<std::string> out;
  std::istringstream iss(s);
  std::string w;
  while (iss >> w) out.push_back(w);
  return out;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <model.onnx> <input.wav> "
                 "[--target \"word1 word2 ...\"]\n",
                 argv[0]);
    return 2;
  }
  const std::string model_path = argv[1];
  const std::string wav_path = argv[2];
  std::string target_str;
  for (int i = 3; i + 1 < argc; ++i) {
    if (std::strcmp(argv[i], "--target") == 0) target_str = argv[i + 1];
  }

  mj::WavFile wav;
  if (!mj::read_wav(wav_path, wav)) {
    std::fprintf(stderr, "! failed to read WAV: %s\n", wav_path.c_str());
    return 1;
  }
  std::printf("· loaded %s — %d Hz, %d ch, %zu samples (%.2f s)\n",
              wav_path.c_str(), wav.sample_rate, wav.channels,
              wav.samples.size(),
              wav.samples.size() / (double)std::max(1, wav.sample_rate));

  void* core = mj_create(model_path.c_str(), /*use_accel*/ 0);
  if (!core) {
    std::fprintf(stderr, "! mj_create failed (check model + vocab.tsv path)\n");
    return 1;
  }
  std::printf("· engine ready, model = %s\n", model_path.c_str());

  // Push lexicon if a target was supplied.
  if (!target_str.empty()) {
    mj_set_target(core, target_str.c_str(), /*beam_width*/ 16);
    std::printf("· target set (%zu words) — beam search with lexicon bias\n",
                split_ws(target_str).size());
  } else {
    std::printf("· no target — greedy decode\n");
  }

  // Stream in 32 ms chunks at the file's native rate.
  const int chunk = std::max(1, wav.sample_rate * 32 / 1000);
  const size_t n = wav.samples.size();
  char buf[2048];
  float conf = 0.0f;

  const auto t0 = std::chrono::steady_clock::now();
  int hops = 0;
  std::string last_text;

  for (size_t off = 0; off < n; off += (size_t)chunk) {
    const int m = (int)std::min((size_t)chunk, n - off);
    mj_push_pcm(core, wav.samples.data() + off, m, wav.sample_rate);

    // Every ~200 ms, run a hop.
    if (((off / chunk) % 6) == 5) {
      const int ran = mj_infer_hop(core, buf, (int)sizeof(buf), &conf);
      if (ran) {
        std::string text(buf);
        if (text != last_text) {
          const double t = std::chrono::duration<double>(
                               std::chrono::steady_clock::now() - t0).count();
          std::printf("[%5.2fs hop#%d c=%.2f] %s\n", t, hops, conf, text.c_str());
          last_text = std::move(text);
        }
      }
      hops++;
    }
  }

  // Final hop after all audio is pushed.
  const int ran = mj_infer_hop(core, buf, (int)sizeof(buf), &conf);
  if (ran) {
    std::printf("─────────────────────────────────────────\n");
    std::printf("FINAL  conf=%.3f\n%s\n", conf, buf);
  } else {
    std::printf("─────────────────────────────────────────\n");
    std::printf("FINAL  (VAD found no speech)\n");
  }

  mj_destroy(core);
  return 0;
}
