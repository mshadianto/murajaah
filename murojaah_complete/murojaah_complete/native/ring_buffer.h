// ring_buffer.h — single-producer / single-consumer lock-free ring buffer.
//
// Producer is the audio callback (mj_push_pcm); consumer is the inference
// hop (mj_infer_hop). One writer, one reader → atomics + memory ordering
// are enough; no mutex on the audio thread.
#ifndef MJ_RING_BUFFER_H
#define MJ_RING_BUFFER_H

#include <atomic>
#include <cstddef>
#include <cstring>
#include <vector>

namespace mj {

template <typename T>
class RingBuffer {
 public:
  explicit RingBuffer(size_t cap) : buf_(cap), cap_(cap) {}

  size_t capacity() const { return cap_; }
  size_t size() const {
    const size_t w = write_.load(std::memory_order_acquire);
    const size_t r = read_.load(std::memory_order_acquire);
    return w - r;
  }
  bool empty() const { return size() == 0; }
  bool full() const { return size() == cap_; }

  // Write n samples from src. If full, drops the oldest to make room
  // (preferred for live audio — keeps the latest window).
  void write(const T* src, size_t n) {
    if (n == 0) return;
    if (n >= cap_) { src += (n - cap_); n = cap_; }
    const size_t r = read_.load(std::memory_order_acquire);
    const size_t w = write_.load(std::memory_order_relaxed);
    const size_t free_space = cap_ - (w - r);
    if (n > free_space) {
      // drop oldest by advancing read pointer
      read_.store(r + (n - free_space), std::memory_order_release);
    }
    const size_t base = w % cap_;
    const size_t first = std::min(n, cap_ - base);
    std::memcpy(buf_.data() + base, src, first * sizeof(T));
    if (n > first) {
      std::memcpy(buf_.data(), src + first, (n - first) * sizeof(T));
    }
    write_.store(w + n, std::memory_order_release);
  }

  // Copy up to n most-recent samples into dst (no advance — peek).
  // Returns the number of samples copied (≤ n).
  size_t peek_tail(T* dst, size_t n) const {
    const size_t w = write_.load(std::memory_order_acquire);
    const size_t r = read_.load(std::memory_order_acquire);
    const size_t avail = w - r;
    if (avail == 0) return 0;
    const size_t take = std::min(n, avail);
    const size_t start_abs = w - take;
    const size_t base = start_abs % cap_;
    const size_t first = std::min(take, cap_ - base);
    std::memcpy(dst, buf_.data() + base, first * sizeof(T));
    if (take > first) std::memcpy(dst + first, buf_.data(), (take - first) * sizeof(T));
    return take;
  }

  void clear() {
    read_.store(0, std::memory_order_release);
    write_.store(0, std::memory_order_release);
  }

 private:
  std::vector<T> buf_;
  size_t cap_;
  std::atomic<size_t> read_{0};
  std::atomic<size_t> write_{0};
};

}  // namespace mj

#endif  // MJ_RING_BUFFER_H
