// ctc_decode.cpp
#include "ctc_decode.h"

#include <cmath>
#include <fstream>
#include <sstream>

namespace mj {

bool CtcDecoder::load(const std::string& vocab_path, int blank_id) {
  std::ifstream in(vocab_path);
  if (!in.is_open()) return false;
  vocab_.clear();
  blank_id_ = blank_id;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    const auto tab = line.find('\t');
    if (tab == std::string::npos) continue;
    const int id = std::stoi(line.substr(0, tab));
    std::string tok = line.substr(tab + 1);
    if ((int)vocab_.size() <= id) vocab_.resize(id + 1, "");
    vocab_[id] = tok;
  }
  return !vocab_.empty();
}

std::string CtcDecoder::decode(const float* logits, int T, int V, float* out_conf) const {
  std::string out;
  out.reserve(T);
  int prev = -1;
  double conf_sum = 0.0;
  int conf_n = 0;

  for (int t = 0; t < T; ++t) {
    const float* row = logits + (size_t)t * V;
    // argmax
    int best = 0;
    float best_v = row[0];
    for (int v = 1; v < V; ++v) {
      if (row[v] > best_v) { best_v = row[v]; best = v; }
    }
    // softmax-prob of the argmax (numerically stable)
    double sumexp = 0.0;
    for (int v = 0; v < V; ++v) sumexp += std::exp((double)row[v] - best_v);
    conf_sum += 1.0 / sumexp;
    conf_n++;

    if (best != prev && best != blank_id_) {
      if (best >= 0 && best < (int)vocab_.size()) {
        const std::string& tok = vocab_[best];
        if (tok == "|") {
          if (!out.empty() && out.back() != ' ') out += ' ';
        } else if (tok.empty() || tok == "<pad>" || tok == "<s>" || tok == "</s>" ||
                   tok == "<unk>") {
          // skip special / empty tokens
        } else {
          out += tok;
        }
      }
    }
    prev = best;
  }
  // trim trailing space
  while (!out.empty() && out.back() == ' ') out.pop_back();
  if (out_conf) *out_conf = conf_n > 0 ? (float)(conf_sum / conf_n) : 0.0f;
  return out;
}

}  // namespace mj
