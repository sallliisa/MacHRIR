#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pointer to C++ CircularBuffer
typedef struct CircularBufferCpp CircularBufferCpp;

/// Create a new circular buffer
CircularBufferCpp *circular_buffer_create(size_t capacity);

/// Destroy circular buffer
void circular_buffer_destroy(CircularBufferCpp *buffer);

/// Write data (returns bytes written)
size_t circular_buffer_write(CircularBufferCpp *buffer, const void *data,
                             size_t size);

/// Read data (returns bytes read)
size_t circular_buffer_read(CircularBufferCpp *buffer, void *data, size_t size);

/// Reset buffer
void circular_buffer_reset(CircularBufferCpp *buffer);

/// Get available bytes for reading
size_t circular_buffer_available_read(const CircularBufferCpp *buffer);

/// Get available bytes for writing
size_t circular_buffer_available_write(const CircularBufferCpp *buffer);

#ifdef __cplusplus
}
#endif
