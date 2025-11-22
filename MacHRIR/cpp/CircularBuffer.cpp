#include "CircularBuffer.hpp"
#include <stdlib.h>

namespace machrir {

CircularBuffer::CircularBuffer(size_t capacity)
    : capacity_(capacity), writeIndex_(0), readIndex_(0) {
  // Allocate 16-byte aligned buffer for potential SIMD operations
  if (posix_memalign(reinterpret_cast<void **>(&buffer_), 16, capacity) != 0) {
    throw std::bad_alloc();
  }
  std::memset(buffer_, 0, capacity);
}

CircularBuffer::~CircularBuffer() { free(buffer_); }

size_t CircularBuffer::write(const void *data, size_t size) noexcept {
  const size_t available = availableWrite();
  const size_t toWrite = std::min(size, available);

  if (toWrite == 0)
    return 0;

  const size_t writeIdx = writeIndex_.load(std::memory_order_relaxed);
  const auto *src = static_cast<const uint8_t *>(data);

  // Handle wrap-around
  const size_t firstChunk = std::min(toWrite, capacity_ - writeIdx);
  std::memcpy(buffer_ + writeIdx, src, firstChunk);

  if (firstChunk < toWrite) {
    std::memcpy(buffer_, src + firstChunk, toWrite - firstChunk);
  }

  // Update write index with release semantics (publish the write)
  writeIndex_.store((writeIdx + toWrite) % capacity_,
                    std::memory_order_release);

  return toWrite;
}

size_t CircularBuffer::read(void *data, size_t size) noexcept {
  const size_t available = availableRead();
  const size_t toRead = std::min(size, available);

  if (toRead == 0)
    return 0;

  const size_t readIdx = readIndex_.load(std::memory_order_relaxed);
  auto *dest = static_cast<uint8_t *>(data);

  // Handle wrap-around
  const size_t firstChunk = std::min(toRead, capacity_ - readIdx);
  std::memcpy(dest, buffer_ + readIdx, firstChunk);

  if (firstChunk < toRead) {
    std::memcpy(dest + firstChunk, buffer_, toRead - firstChunk);
  }

  // Update read index with release semantics
  readIndex_.store((readIdx + toRead) % capacity_, std::memory_order_release);

  return toRead;
}

void CircularBuffer::reset() noexcept {
  writeIndex_.store(0, std::memory_order_relaxed);
  readIndex_.store(0, std::memory_order_relaxed);
  std::memset(buffer_, 0, capacity_);
}

size_t CircularBuffer::availableRead() const noexcept {
  const size_t writeIdx = writeIndex_.load(std::memory_order_acquire);
  const size_t readIdx = readIndex_.load(std::memory_order_relaxed);

  if (writeIdx >= readIdx) {
    return writeIdx - readIdx;
  } else {
    return capacity_ - (readIdx - writeIdx);
  }
}

size_t CircularBuffer::availableWrite() const noexcept {
  const size_t writeIdx = writeIndex_.load(std::memory_order_relaxed);
  const size_t readIdx = readIndex_.load(std::memory_order_acquire);

  if (writeIdx >= readIdx) {
    return capacity_ - (writeIdx - readIdx) - 1;
  } else {
    return readIdx - writeIdx - 1;
  }
}

} // namespace machrir
