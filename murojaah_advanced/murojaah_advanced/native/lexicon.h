// lexicon.h — active expected-word lexicon for biased CTC beam search.
//
// At each alignment cursor advance, the Dart side hands us a small window
// of next-expected words (loose-keyed, harakat-stripped). During beam
// expansion we score each beam's in-progress word against this window:
//   * exact match    → +complete_bonus  (a beam that lands on an expected word)
//   * strict prefix  → +partial_bonus   (a beam that's heading toward one)
//   * neither        →  0
//
// The window is small (≤ 8 words), so a flat linear scan is faster than
// any trie. Kept lock-free on the read side: the orchestrator swaps the
// shared_ptr<Lexicon> atomically when the cursor moves.
#ifndef MJ_LEXICON_H
#define MJ_LEXICON_H

#include <string>
#include <vector>

namespace mj {

class Lexicon {
 public:
  void set_words(const std::vector<std::string>& loose_words);
  bool empty() const { return words_.empty(); }

  // Score a beam's in-progress word (since last space).
  // Returns 0 when in_word is empty (avoid biasing fresh beams).
  float score(const std::string& in_word) const;

  // Configurable bonuses (log-prob space).
  float partial_bonus = 0.35f;
  float complete_bonus = 1.20f;

 private:
  std::vector<std::string> words_;
};

}  // namespace mj

#endif  // MJ_LEXICON_H
