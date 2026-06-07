// ctc_decode.h — greedy CTC decoder with confidence estimate.
//
// Vocabulary is loaded from a TSV file written by the export script:
//   <id>\t<utf8_token>\n
// Token "|" is conventionally the word separator in Wav2Vec2-CTC and is
// emitted as a space; "<pad>" / "<s>" / "</s>" / "<unk>" are dropped.
#ifndef MJ_CTC_DECODE_H
#define MJ_CTC_DECODE_H

#include <string>
#include <vector>

namespace mj {

class CtcDecoder {
 public:
  // Load vocab.tsv. blank_id is the CTC blank token id (commonly 0).
  bool load(const std::string& vocab_path, int blank_id = 0);

  // Greedy decode of logits with shape [T, V] (row-major).
  // Writes mean per-frame confidence (0..1) into *out_conf if non-null.
  std::string decode(const float* logits, int T, int V, float* out_conf = nullptr) const;

  int vocab_size() const { return (int)vocab_.size(); }
  int blank_id() const { return blank_id_; }

 private:
  std::vector<std::string> vocab_;  // id → UTF-8 token
  int blank_id_ = 0;
};

}  // namespace mj

#endif  // MJ_CTC_DECODE_H
