#pragma once
#include <atomic>
#include <cstdint>
#include <cstring>
#include <algorithm>

namespace machrir {

/// Lock-free single-producer-single-consumer circular buffer
/// Optimized for real-time audio threads (no locks, no allocations)
class CircularBuffer {
public:
    explicit CircularBuffer(size_t capacity);
    ~CircularBuffer();

    // Delete copy/move (non-copyable due to aligned memory)
    CircularBuffer(const CircularBuffer&) = delete;
    CircularBuffer& operator=(const CircularBuffer&) = delete;

    /// Write data to buffer (producer thread only)
    /// Returns number of bytes actually written
    size_t write(const void* data, size_t size) noexcept;

    /// Read data from buffer (consumer thread only)
    /// Returns number of bytes actually read
    size_t read(void* data, size_t size) noexcept;

    /// Reset buffer (must be called when both threads are stopped)
    void reset() noexcept;

    /// Get available bytes for reading
    size_t availableRead() const noexcept;

    /// Get available bytes for writing
    size_t availableWrite() const noexcept;

private:
    uint8_t* buffer_;
    size_t capacity_;

    // Atomic indices using relaxed memory order for performance
    // SPSC queue allows relaxed ordering between producer/consumer
    alignas(64) std::atomic<size_t> writeIndex_;  // Cache line aligned
    alignas(64) std::atomic<size_t> readIndex_;   // Separate cache line

    size_t nextIndex(size_t current) const noexcept {
        return (current + 1) % capacity_;
    }
};

} // namespace machrir
