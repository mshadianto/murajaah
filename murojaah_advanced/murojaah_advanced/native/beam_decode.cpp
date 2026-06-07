// beam_decode.cpp
#include "beam_decode.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>
#include <unordered_map>

namespace mj {

namespace {

constexpr double kNegInf = -std::numeric_limits<double>::infinity();

inline double log_sum_exp(double a, double b) {
  if (a == kNegInf) return b;
  if (b == kNegInf) return a;
  if (a > b) return a + std::log1p(std::exp(b - a));
  return b + std::log1p(std::exp(a - b));
}

// Stable log-softmax of a row of length V into out[].
inline void log_softmax_row(const float* row, int V, std::vector<double>& out) {
  out.resize(V);
  float mx = row[0];
  for (int v = 1; v < V; ++v) if (row[v] > mx) mx = row[v];
  double sum = 0.0;
  for (int v = 0; v < V; ++v) sum += std::exp((double)row[v] - mx);
  const double log_z = (double)mx + std::log(sum);
  for (int v = 0; v < V; ++v) out[v] = (double)row[v] - log_z;
}

// Indices of the top-K largest entries of `vals` (length V), descending.
inline void top_k(const std::vector<double>& vals, int K, std::vector<int>& out) {
  const int V = (int)vals.size();
  out.resize(V);
  for (int v = 0; v < V; ++v) out[v] = v;
  if (K >= V) {
    std::sort(out.begin(), out.end(),
              [&](int a, int b) { return vals[a] > vals[b]; });
    return;
  }
  std::partial_sort(out.begin(), out.begin() + K, out.end(),
                    [&](int a, int b) { return vals[a] > vals[b]; });
  out.resize(K);
}

// Beam state: (text-so-far, in-progress-word, lp_blank, lp_no_blank).
struct Beam {
  std::string text;
  std::string in_word;
  double lp_b = kNegInf;   // ends-in-blank
  double lp_nb = kNegInf;  // ends-in-symbol
  double total() const { return log_sum_exp(lp_b, lp_nb); }
};

// Unique key for merging identical (text, in_word) beams.
struct BeamKey {
  std::string text;
  std::string in_word;
  bool operator==(const BeamKey& o) const {
    return text == o.text && in_word == o.in_word;
  }
};
struct BeamKeyHash {
  size_t operator()(const BeamKey& k) const noexcept {
    // FNV-1a-ish mix of two strings
    std::hash<std::string> H;
    return H(k.text) * 1315423911u ^ H(k.in_word);
  }
};

}  // namespace

bool BeamDecoder::load_vocab(const std::string& vocab_path, int blank_id) {
  std::ifstream in(vocab_path);
  if (!in.is_open()) return false;
  vocab_.clear();
  blank_id_ = blank_id;
  word_sep_id_ = -1;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    const auto tab = line.find('\t');
    if (tab == std::string::npos) continue;
    const int id = std::stoi(line.substr(0, tab));
    std::string tok = line.substr(tab + 1);
    if ((int)vocab_.size() <= id) vocab_.resize(id + 1, "");
    vocab_[id] = tok;
    if (tok == "|") word_sep_id_ = id;
  }
  return !vocab_.empty();
}

std::string BeamDecoder::decode(const float* logits, int T, int V,
                                const Lexicon* lex, float* out_conf,
                                const BeamConfig& cfg) const {
  using BeamMap = std::unordered_map<BeamKey, Beam, BeamKeyHash>;

  // Init: single empty beam, all-blank prob = 0.
  BeamMap cur;
  cur.reserve((size_t)cfg.beam_width * 4);
  cur[{"", ""}] = {"", "", /*lp_b*/ 0.0, /*lp_nb*/ kNegInf};

  std::vector<double> lp_row;
  std::vector<int> top_idx;
  double conf_sum = 0.0;
  int conf_n = 0;

  for (int t = 0; t < T; ++t) {
    log_softmax_row(logits + (size_t)t * V, V, lp_row);
    top_k(lp_row, cfg.prune_top_k, top_idx);

    // Track max prob (softmax) for confidence.
    double max_p = -1.0;
    for (int v = 0; v < V; ++v) {
      const double p = std::exp(lp_row[v]);
      if (p > max_p) max_p = p;
    }
    conf_sum += max_p;
    conf_n++;

    BeamMap next;
    next.reserve(cur.size() * cfg.prune_top_k);

    auto add = [&](const BeamKey& key, double lp_b_add, double lp_nb_add) {
      auto it = next.find(key);
      if (it == next.end()) {
        Beam b;
        b.text = key.text;
        b.in_word = key.in_word;
        b.lp_b = lp_b_add;
        b.lp_nb = lp_nb_add;
        next.emplace(key, std::move(b));
      } else {
        it->second.lp_b = log_sum_exp(it->second.lp_b, lp_b_add);
        it->second.lp_nb = log_sum_exp(it->second.lp_nb, lp_nb_add);
      }
    };

    for (const auto& kv : cur) {
      const Beam& b = kv.second;

      for (int v : top_idx) {
        const double lp_v = lp_row[v];

        // Case 1: blank — text and in_word unchanged.
        if (v == blank_id_) {
          add({b.text, b.in_word},
              log_sum_exp(b.lp_b + lp_v, b.lp_nb + lp_v),
              kNegInf);
          continue;
        }

        // Case 2: non-blank symbol.
        const std::string& tok = (v >= 0 && v < (int)vocab_.size()) ? vocab_[v] : "";
        if (tok.empty() || tok == "<pad>" || tok == "<unk>" || tok == "<s>" ||
            tok == "</s>") {
          continue;
        }

        // Sub-case 2a: word separator "|" — commit current in_word to text.
        if (v == word_sep_id_) {
          std::string new_text = b.text;
          if (!b.in_word.empty()) new_text += b.in_word;
          if (!new_text.empty() && new_text.back() != ' ') new_text += ' ';
          // CTC same-token rule applies to "|" too: a "|" right after another
          // "|" (in_word still empty) only counts when there was a blank
          // between them; otherwise it's collapsed.
          if (b.in_word.empty()) {
            add({new_text, ""}, kNegInf, b.lp_b + lp_v);
          } else {
            add({new_text, ""}, kNegInf,
                log_sum_exp(b.lp_b + lp_v, b.lp_nb + lp_v));
          }
          continue;
        }

        // Sub-case 2b: same as last emitted char (need a blank between dups).
        const std::string last_tok =
            b.in_word.empty() ? std::string() :
            // last UTF-8 codepoint of in_word (Arabic chars are 2 bytes;
            // robust: just use last 2 bytes if the lead byte signals 2-byte
            // UTF-8; otherwise treat as 1 byte).
            [&]() -> std::string {
              const size_t n = b.in_word.size();
              if (n == 0) return "";
              size_t i = n - 1;
              while (i > 0 && (((unsigned char)b.in_word[i] & 0xC0) == 0x80)) --i;
              return b.in_word.substr(i);
            }();

        if (tok == last_tok) {
          // (a) collapse: keep in_word, extend from lp_nb only (no blank between)
          add({b.text, b.in_word}, kNegInf, b.lp_nb + lp_v);
          // (b) genuine duplicate after blank: extend from lp_b
          std::string new_iw = b.in_word + tok;
          BeamKey k{b.text, new_iw};
          double lex_bonus = lex ? (double)lex->score(new_iw) : 0.0;
          add(k, kNegInf, b.lp_b + lp_v + lex_bonus);
        } else {
          // brand-new symbol — extend regardless of prior end-state
          std::string new_iw = b.in_word + tok;
          BeamKey k{b.text, new_iw};
          double lex_bonus = lex ? (double)lex->score(new_iw) : 0.0;
          add(k, kNegInf,
              log_sum_exp(b.lp_b + lp_v, b.lp_nb + lp_v) + lex_bonus);
        }
      }
    }

    // Prune to top beam_width by total log-prob.
    std::vector<std::pair<double, BeamKey>> ranked;
    ranked.reserve(next.size());
    for (auto& kv : next) ranked.push_back({kv.second.total(), kv.first});
    if ((int)ranked.size() > cfg.beam_width) {
      std::partial_sort(
          ranked.begin(), ranked.begin() + cfg.beam_width, ranked.end(),
          [](const auto& a, const auto& b) { return a.first > b.first; });
      ranked.resize(cfg.beam_width);
    }
    cur.clear();
    cur.reserve(ranked.size());
    for (auto& r : ranked) {
      auto it = next.find(r.second);
      if (it != next.end()) cur.emplace(r.second, std::move(it->second));
    }
  }

  // Pick best surviving beam (including any in-progress word).
  const Beam* best = nullptr;
  double best_lp = kNegInf;
  for (auto& kv : cur) {
    const double tp = kv.second.total();
    if (tp > best_lp) { best_lp = tp; best = &kv.second; }
  }
  std::string out;
  if (best) {
    out = best->text;
    if (!best->in_word.empty()) {
      if (!out.empty() && out.back() != ' ') out += ' ';
      out += best->in_word;
    }
    while (!out.empty() && out.back() == ' ') out.pop_back();
  }
  if (out_conf) *out_conf = conf_n > 0 ? (float)(conf_sum / conf_n) : 0.0f;
  return out;
}

}  // namespace mj
