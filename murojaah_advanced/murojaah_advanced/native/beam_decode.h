// beam_decode.h — prefix-beam CTC decoder with optional lexicon bias.
//
// This is the accuracy upgrade over greedy decode: maintains K active
// hypotheses per frame, prunes by total log-prob, and (when a lexicon is
// active) biases beams whose in-progress word matches expected next words
// from the alignment cursor.
//
// Beam state tracks separate "ends-in-blank" and "ends-in-symbol" log-probs
// so the CTC collapse rule is handled correctly without lattice tricks.
#ifndef MJ_BEAM_DECODE_H
#define MJ_BEAM_DECODE_H

#include <string>
#include <vector>

#include "lexicon.h"

namespace mj {

struct BeamConfig {
  int beam_width = 16;       // active beams retained per frame
  int prune_top_k = 8;       // tokens considered per frame per beam
  int blank_id = 0;          // CTC blank token id
};

class BeamDecoder {
 public:
  // vocab: id → UTF-8 token (same TSV file as the greedy decoder).
  bool load_vocab(const std::string& vocab_path, int blank_id = 0);

  // Run a hop. lex may be nullptr (then this is pure beam search with no bias).
  // Writes mean per-frame confidence into *out_conf if non-null.
  std::string decode(const float* logits, int T, int V,
                     const Lexicon* lex, float* out_conf,
                     const BeamConfig& cfg = {}) const;

  int vocab_size() const { return (int)vocab_.size(); }

 private:
  std::vector<std::string> vocab_;
  int blank_id_ = 0;
  int word_sep_id_ = -1;  // resolved from vocab on load (token "|")
};

}  // namespace mj

#endif  // MJ_BEAM_DECODE_H
