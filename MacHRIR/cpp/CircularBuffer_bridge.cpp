#include "CircularBuffer_bridge.h"
#include "CircularBuffer.hpp"

extern "C" {

CircularBufferCpp *circular_buffer_create(size_t capacity) {
  try {
    return reinterpret_cast<CircularBufferCpp *>(
        new machrir::CircularBuffer(capacity));
  } catch (...) {
    return nullptr;
  }
}

void circular_buffer_destroy(CircularBufferCpp *buffer) {
  delete reinterpret_cast<machrir::CircularBuffer *>(buffer);
}

size_t circular_buffer_write(CircularBufferCpp *buffer, const void *data,
                             size_t size) {
  auto *cb = reinterpret_cast<machrir::CircularBuffer *>(buffer);
  return cb->write(data, size);
}

size_t circular_buffer_read(CircularBufferCpp *buffer, void *data,
                            size_t size) {
  auto *cb = reinterpret_cast<machrir::CircularBuffer *>(buffer);
  return cb->read(data, size);
}

void circular_buffer_reset(CircularBufferCpp *buffer) {
  auto *cb = reinterpret_cast<machrir::CircularBuffer *>(buffer);
  cb->reset();
}

size_t circular_buffer_available_read(const CircularBufferCpp *buffer) {
  const auto *cb = reinterpret_cast<const machrir::CircularBuffer *>(buffer);
  return cb->availableRead();
}

size_t circular_buffer_available_write(const CircularBufferCpp *buffer) {
  const auto *cb = reinterpret_cast<const machrir::CircularBuffer *>(buffer);
  return cb->availableWrite();
}

} // extern "C"
