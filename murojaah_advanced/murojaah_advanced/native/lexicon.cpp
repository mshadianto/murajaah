// lexicon.cpp
#include "lexicon.h"

namespace mj {

void Lexicon::set_words(const std::vector<std::string>& loose_words) {
  words_.clear();
  words_.reserve(loose_words.size());
  for (const auto& w : loose_words) {
    if (!w.empty()) words_.push_back(w);
  }
}

float Lexicon::score(const std::string& in_word) const {
  if (in_word.empty() || words_.empty()) return 0.0f;
  float best = 0.0f;
  for (const auto& w : words_) {
    if (w == in_word) {
      if (complete_bonus > best) best = complete_bonus;
    } else if (w.size() > in_word.size() &&
               w.compare(0, in_word.size(), in_word) == 0) {
      if (partial_bonus > best) best = partial_bonus;
    }
  }
  return best;
}

}  // namespace mj
