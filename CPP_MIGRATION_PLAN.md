# C++ Migration Plan: CircularBuffer and Audio Callbacks

## Overview

This document outlines the plan to migrate performance-critical components from Swift to C++ for improved real-time audio processing performance.

**Target Components**:
1. CircularBuffer (Swift → Lock-free C++ SPSC queue)
2. Audio callbacks (Swift → Pure C++ callbacks)

**Expected Benefits**:
- Eliminate lock contention in CircularBuffer (NSLock → lock-free atomics)
- Remove Swift runtime overhead in real-time audio threads
- Guarantee zero allocations in critical path
- Better compiler optimization opportunities

**Risk Level**: Medium (core audio path changes)

---

## Phase 1: Lock-Free CircularBuffer Migration

### Current Implementation Analysis

**File**: `MacHRIR/CircularBuffer.swift`

**Current approach**:
- NSLock for thread synchronization
- Manual index management with modulo wrapping
- Two operations: `write(data:size:)` and `read(into:size:)`
- Used between input callback (producer) and output callback (consumer)

**Problem**: Lock acquisition in real-time audio threads can cause priority inversion and glitches.

### Target Implementation

**New files to create**:
```
MacHRIR/
├── cpp/
│   ├── CircularBuffer.hpp        # Lock-free SPSC ring buffer
│   ├── CircularBuffer.cpp        # Implementation
│   └── CircularBuffer_bridge.h   # C-compatible bridge for Swift
```

**Technology**: Single-Producer-Single-Consumer (SPSC) lock-free queue using C++ atomics

### Implementation Details

#### CircularBuffer.hpp
```cpp
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
```

#### Key Design Decisions

**Memory ordering**:
- Use `std::memory_order_relaxed` for index updates (SPSC allows this)
- Use `std::memory_order_acquire`/`release` only if issues arise
- SPSC queues don't need sequential consistency

**Cache line alignment**:
- Separate `writeIndex_` and `readIndex_` to different cache lines (64-byte aligned)
- Prevents false sharing between producer/consumer threads

**Buffer allocation**:
- Use aligned allocation (16-byte minimum for SIMD)
- Consider using `posix_memalign` or `aligned_alloc`

#### CircularBuffer.cpp
```cpp
#include "CircularBuffer.hpp"
#include <stdlib.h>

namespace machrir {

CircularBuffer::CircularBuffer(size_t capacity)
    : capacity_(capacity)
    , writeIndex_(0)
    , readIndex_(0)
{
    // Allocate 16-byte aligned buffer for potential SIMD operations
    if (posix_memalign(reinterpret_cast<void**>(&buffer_), 16, capacity) != 0) {
        throw std::bad_alloc();
    }
    std::memset(buffer_, 0, capacity);
}

CircularBuffer::~CircularBuffer() {
    free(buffer_);
}

size_t CircularBuffer::write(const void* data, size_t size) noexcept {
    const size_t available = availableWrite();
    const size_t toWrite = std::min(size, available);

    if (toWrite == 0) return 0;

    const size_t writeIdx = writeIndex_.load(std::memory_order_relaxed);
    const auto* src = static_cast<const uint8_t*>(data);

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

size_t CircularBuffer::read(void* data, size_t size) noexcept {
    const size_t available = availableRead();
    const size_t toRead = std::min(size, available);

    if (toRead == 0) return 0;

    const size_t readIdx = readIndex_.load(std::memory_order_relaxed);
    auto* dest = static_cast<uint8_t*>(data);

    // Handle wrap-around
    const size_t firstChunk = std::min(toRead, capacity_ - readIdx);
    std::memcpy(dest, buffer_ + readIdx, firstChunk);

    if (firstChunk < toRead) {
        std::memcpy(dest + firstChunk, buffer_, toRead - firstChunk);
    }

    // Update read index with release semantics
    readIndex_.store((readIdx + toRead) % capacity_,
                     std::memory_order_release);

    return toRead;
}

void CircularBuffer::reset() noexcept {
    writeIndex_.store(0, std::memory_order_relaxed);
    readIndex_.store(0, std::memory_order_relaxed);
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
```

#### CircularBuffer_bridge.h (C Bridge for Swift)
```c
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pointer to C++ CircularBuffer
typedef struct CircularBufferCpp CircularBufferCpp;

/// Create a new circular buffer
CircularBufferCpp* circular_buffer_create(size_t capacity);

/// Destroy circular buffer
void circular_buffer_destroy(CircularBufferCpp* buffer);

/// Write data (returns bytes written)
size_t circular_buffer_write(CircularBufferCpp* buffer, const void* data, size_t size);

/// Read data (returns bytes read)
size_t circular_buffer_read(CircularBufferCpp* buffer, void* data, size_t size);

/// Reset buffer
void circular_buffer_reset(CircularBufferCpp* buffer);

/// Get available bytes for reading
size_t circular_buffer_available_read(const CircularBufferCpp* buffer);

/// Get available bytes for writing
size_t circular_buffer_available_write(const CircularBufferCpp* buffer);

#ifdef __cplusplus
}
#endif
```

#### CircularBuffer_bridge.cpp
```cpp
#include "CircularBuffer_bridge.h"
#include "CircularBuffer.hpp"

extern "C" {

CircularBufferCpp* circular_buffer_create(size_t capacity) {
    try {
        return reinterpret_cast<CircularBufferCpp*>(
            new machrir::CircularBuffer(capacity)
        );
    } catch (...) {
        return nullptr;
    }
}

void circular_buffer_destroy(CircularBufferCpp* buffer) {
    delete reinterpret_cast<machrir::CircularBuffer*>(buffer);
}

size_t circular_buffer_write(CircularBufferCpp* buffer, const void* data, size_t size) {
    auto* cb = reinterpret_cast<machrir::CircularBuffer*>(buffer);
    return cb->write(data, size);
}

size_t circular_buffer_read(CircularBufferCpp* buffer, void* data, size_t size) {
    auto* cb = reinterpret_cast<machrir::CircularBuffer*>(buffer);
    return cb->read(data, size);
}

void circular_buffer_reset(CircularBufferCpp* buffer) {
    auto* cb = reinterpret_cast<machrir::CircularBuffer*>(buffer);
    cb->reset();
}

size_t circular_buffer_available_read(const CircularBufferCpp* buffer) {
    const auto* cb = reinterpret_cast<const machrir::CircularBuffer*>(buffer);
    return cb->availableRead();
}

size_t circular_buffer_available_write(const CircularBufferCpp* buffer) {
    const auto* cb = reinterpret_cast<const machrir::CircularBuffer*>(buffer);
    return cb->availableWrite();
}

} // extern "C"
```

### Swift Integration

**Modified**: `MacHRIR/CircularBuffer.swift`

```swift
import Foundation

/// Swift wrapper around C++ lock-free circular buffer
class CircularBuffer {
    private var cppBuffer: OpaquePointer?
    private let size: Int

    init(size: Int) {
        self.size = size
        self.cppBuffer = circular_buffer_create(size)

        guard cppBuffer != nil else {
            fatalError("Failed to create C++ circular buffer")
        }
    }

    deinit {
        if let buffer = cppBuffer {
            circular_buffer_destroy(buffer)
        }
    }

    func write(data: UnsafeRawPointer, size: Int) {
        guard let buffer = cppBuffer else { return }
        _ = circular_buffer_write(buffer, data, size)
    }

    func read(into data: UnsafeMutableRawPointer, size: Int) -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_read(buffer, data, size)
    }

    func reset() {
        guard let buffer = cppBuffer else { return }
        circular_buffer_reset(buffer)
    }

    func availableRead() -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_available_read(buffer)
    }

    func availableWrite() -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_available_write(buffer)
    }
}
```

### Xcode Project Configuration

**Add to MacHRIR.xcodeproj**:

1. Create new C++ files group
2. Add all `.hpp`, `.cpp`, `.h` files
3. Configure build settings:
   - **C++ Language Dialect**: GNU++17 or C++17
   - **C++ Standard Library**: libc++ (default on macOS)
   - **Optimization Level**: `-O3` for Release
   - **Enable Link-Time Optimization**: Yes (Release)
   - **Other C++ Flags**: `-march=native -ffast-math` (Release only)

4. Add bridging header if not already present:
   - Import `CircularBuffer_bridge.h` in bridging header

### Testing Plan for Phase 1

#### Unit Tests
```swift
// Test basic read/write
func testCircularBufferBasicReadWrite() {
    let buffer = CircularBuffer(size: 1024)
    let writeData: [Float] = [1.0, 2.0, 3.0, 4.0]

    writeData.withUnsafeBytes { ptr in
        buffer.write(data: ptr.baseAddress!, size: ptr.count)
    }

    var readData = [Float](repeating: 0, count: 4)
    let bytesRead = readData.withUnsafeMutableBytes { ptr in
        buffer.read(into: ptr.baseAddress!, size: ptr.count)
    }

    XCTAssertEqual(bytesRead, writeData.count * MemoryLayout<Float>.size)
    XCTAssertEqual(readData, writeData)
}

// Test wrap-around
func testCircularBufferWrapAround() {
    // Fill buffer, read some, write more
    // Verify wrap-around works correctly
}

// Test concurrent access (producer/consumer threads)
func testCircularBufferThreadSafety() {
    // Spawn producer and consumer threads
    // Verify no data corruption
}
```

#### Integration Tests
1. Run app with C++ buffer, verify audio passes through correctly
2. Switch devices while running
3. Monitor for buffer underruns/overruns
4. Run for extended period (30+ minutes)

#### Performance Benchmarks
```swift
// Measure write latency
func benchmarkCircularBufferWrite() {
    let buffer = CircularBuffer(size: 65536)
    let data = [Float](repeating: 1.0, count: 512)

    measure {
        for _ in 0..<10000 {
            data.withUnsafeBytes { ptr in
                buffer.write(data: ptr.baseAddress!, size: ptr.count)
            }
        }
    }
}
```

**Compare**: Swift NSLock version vs C++ lock-free version

---

## Phase 2: Audio Callbacks Migration

### Current Implementation Analysis

**File**: `MacHRIR/AudioGraphManager.swift`

**Current callbacks**:
1. `inputRenderCallback` - Pulls audio from input device, writes to CircularBuffer
2. `renderCallback` - Reads from CircularBuffer, processes through HRIR, outputs to device

**Swift overhead in callbacks**:
- ARC retain/release on context object
- Potential hidden allocations
- Swift runtime calls

### Target Implementation

**New files to create**:
```
MacHRIR/
├── cpp/
│   ├── AudioCallbackContext.hpp    # C++ context for callbacks
│   ├── AudioCallbackContext.cpp
│   ├── AudioCallbacks.hpp          # Callback implementations
│   ├── AudioCallbacks.cpp
│   └── AudioCallbacks_bridge.h     # C bridge
```

### Implementation Details

#### AudioCallbackContext.hpp
```cpp
#pragma once
#include "CircularBuffer.hpp"
#include <CoreAudio/CoreAudio.h>
#include <cstdint>

namespace machrir {

/// Context for audio callbacks (replaces Swift AudioGraphManager reference)
struct AudioCallbackContext {
    CircularBuffer* circularBuffer;

    // Channel configuration
    uint32_t inputChannelCount;
    uint32_t outputChannelCount;

    // Pre-allocated buffers for interleaving/deinterleaving
    float* inputInterleaveBuffer;
    float* outputInterleaveBuffer;
    size_t maxFramesPerCallback;

    // HRIR processing function pointer (called from output callback)
    // Will be set by Swift/HRIRManager
    void (*hrirProcessFunc)(void* hrirContext,
                           float** inputChannels,
                           uint32_t channelCount,
                           float* leftOutput,
                           float* rightOutput,
                           uint32_t frameCount);
    void* hrirContext;

    // Statistics (for debugging, use atomics if accessed from multiple threads)
    std::atomic<uint64_t> inputCallbackCount;
    std::atomic<uint64_t> outputCallbackCount;
    std::atomic<uint64_t> bufferUnderrunCount;

    AudioCallbackContext(size_t bufferSize,
                        uint32_t maxFrames,
                        uint32_t maxChannels);
    ~AudioCallbackContext();
};

} // namespace machrir
```

#### AudioCallbacks.hpp
```cpp
#pragma once
#include <CoreAudio/CoreAudio.h>

extern "C" {

/// Input callback (pulls from input device, writes to circular buffer)
OSStatus cpp_input_render_callback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData
);

/// Output callback (reads from circular buffer, processes HRIR, outputs)
OSStatus cpp_output_render_callback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData
);

} // extern "C"
```

#### AudioCallbacks.cpp
```cpp
#include "AudioCallbacks.hpp"
#include "AudioCallbackContext.hpp"
#include <algorithm>

extern "C" {

OSStatus cpp_input_render_callback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData
) {
    auto* context = static_cast<machrir::AudioCallbackContext*>(inRefCon);

    // TODO: Implement input callback logic
    // 1. Allocate AudioBufferList for pulling audio
    // 2. AudioUnitRender to get data from input device
    // 3. Interleave channels into buffer
    // 4. Write to CircularBuffer
    // 5. Update statistics

    context->inputCallbackCount.fetch_add(1, std::memory_order_relaxed);

    return noErr;
}

OSStatus cpp_output_render_callback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData
) {
    auto* context = static_cast<machrir::AudioCallbackContext*>(inRefCon);

    // TODO: Implement output callback logic
    // 1. Read interleaved data from CircularBuffer
    // 2. De-interleave into per-channel buffers
    // 3. Call HRIR processing function (if enabled)
    // 4. Write stereo output to ioData
    // 5. Handle underruns gracefully

    context->outputCallbackCount.fetch_add(1, std::memory_order_relaxed);

    return noErr;
}

} // extern "C"
```

#### Key Design Decisions

**HRIR Processing Integration**:
- Use function pointer to call back into Swift/C++ HRIRManager
- Avoids duplicating convolution code
- Allows gradual migration (can keep ConvolutionEngine in Swift initially)

**Buffer Management**:
- Pre-allocate all buffers in `AudioCallbackContext` constructor
- Zero allocations in callbacks (guaranteed)

**Error Handling**:
- No exceptions in callbacks (noexcept functions)
- Graceful degradation on errors (output silence, not crash)

### Swift Integration

**Modified**: `MacHRIR/AudioGraphManager.swift`

```swift
class AudioGraphManager: ObservableObject {
    // Replace CircularBuffer with C++ version (already done in Phase 1)

    // Add C++ callback context
    private var cppCallbackContext: OpaquePointer?

    init() {
        // Create C++ callback context
        cppCallbackContext = audio_callback_context_create(
            bufferSize: 65536,
            maxFrames: 4096,
            maxChannels: 16
        )

        // Set up HRIR processing callback
        audio_callback_context_set_hrir_processor(
            cppCallbackContext,
            hrirProcessingBridge,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func setupInputCallback() {
        var callback = AURenderCallbackStruct(
            inputProc: cpp_input_render_callback,  // C++ function
            inputProcRefCon: UnsafeMutableRawPointer(cppCallbackContext)
        )

        AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
    }

    func setupOutputCallback() {
        var callback = AURenderCallbackStruct(
            inputProc: cpp_output_render_callback,  // C++ function
            inputProcRefCon: UnsafeMutableRawPointer(cppCallbackContext)
        )

        AudioUnitSetProperty(
            outputUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
    }
}

// Bridge function called from C++ to process HRIR
private func hrirProcessingBridge(
    _ hrirContext: UnsafeMutableRawPointer?,
    _ inputChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
    _ channelCount: UInt32,
    _ leftOutput: UnsafeMutablePointer<Float>?,
    _ rightOutput: UnsafeMutablePointer<Float>?,
    _ frameCount: UInt32
) {
    guard let context = hrirContext else { return }
    let manager = Unmanaged<AudioGraphManager>.fromOpaque(context).takeUnretainedValue()

    // Call into HRIRManager
    // manager.hrirManager?.processAudio(...)
}
```

### Testing Plan for Phase 2

#### Unit Tests
- Verify callbacks are called with correct parameters
- Test HRIR processing bridge
- Verify channel count handling

#### Integration Tests
1. Compare audio output: Swift callbacks vs C++ callbacks
2. Verify identical processing results
3. Check for glitches, dropouts
4. Test device switching
5. Test start/stop cycles

#### Performance Benchmarks
- Measure callback execution time (Time Profiler in Instruments)
- Compare Swift vs C++ callback latency
- Measure CPU usage under load

---

## Migration Execution Timeline

### Week 1: Preparation
- [ ] Set up C++ build configuration in Xcode
- [ ] Create `cpp/` directory structure
- [ ] Add bridging header
- [ ] Verify C++ compilation works (hello world test)

### Week 2: CircularBuffer Migration
- [ ] Implement `CircularBuffer.hpp/.cpp`
- [ ] Implement `CircularBuffer_bridge.h/.cpp`
- [ ] Update Swift `CircularBuffer.swift` wrapper
- [ ] Write unit tests
- [ ] Performance benchmarks (Swift vs C++)
- [ ] Code review

### Week 3: CircularBuffer Integration
- [ ] Integrate into AudioGraphManager
- [ ] Run integration tests
- [ ] Fix any issues
- [ ] Extended stability testing (overnight runs)
- [ ] Performance validation in real app

### Week 4: Audio Callbacks Migration (Part 1)
- [ ] Implement `AudioCallbackContext.hpp/.cpp`
- [ ] Implement bridge functions
- [ ] Implement input callback in C++
- [ ] Test input callback in isolation

### Week 5: Audio Callbacks Migration (Part 2)
- [ ] Implement output callback in C++
- [ ] Implement HRIR processing bridge
- [ ] Integration testing
- [ ] Performance benchmarking

### Week 6: Validation and Optimization
- [ ] A/B testing (Swift vs C++ callbacks)
- [ ] Profile with Instruments
- [ ] Optimize hot paths
- [ ] Document performance improvements
- [ ] Final code review

---

## Performance Measurement Plan

### Metrics to Track

#### Before Migration (Baseline)
1. **Callback latency**: Time spent in each callback (measure with `mach_absolute_time()`)
2. **CPU usage**: % CPU during playback (Activity Monitor / Instruments)
3. **Buffer statistics**: Underrun/overrun count over 1-hour test
4. **Memory**: Peak memory usage
5. **Jitter**: Variance in callback timing

#### After Each Phase
- Re-measure all baseline metrics
- Calculate improvement percentages
- Document any regressions

### Benchmark Code Template

```cpp
// In callback (development builds only, disabled in release)
#ifdef MEASURE_PERFORMANCE
uint64_t start = mach_absolute_time();
#endif

// ... callback work ...

#ifdef MEASURE_PERFORMANCE
uint64_t end = mach_absolute_time();
uint64_t elapsed = end - start;
// Log to atomic counter or lock-free queue for later analysis
#endif
```

### Success Criteria

**Phase 1 (CircularBuffer)**:
- Zero lock contention (verified with Thread Sanitizer)
- ≥10% reduction in callback latency variance
- No audio glitches in 24-hour stability test

**Phase 2 (Audio Callbacks)**:
- ≥20% reduction in callback execution time
- ≥5% reduction in overall CPU usage
- Zero regressions in audio quality

---

## Rollback Plan

### If Issues Arise

**Phase 1 Rollback**:
1. Revert `CircularBuffer.swift` to use NSLock version
2. Remove C++ files from build
3. Test original implementation
4. Investigation period: Analyze what went wrong

**Phase 2 Rollback**:
1. Revert callback setup in `AudioGraphManager.swift`
2. Restore original Swift callbacks
3. Keep C++ CircularBuffer if Phase 1 was successful
4. Investigation period

### Feature Flags

Consider adding compile-time flag:
```swift
#if USE_CPP_CALLBACKS
    // C++ callback setup
#else
    // Swift callback setup
#endif
```

Allows easy A/B testing and quick rollback.

---

## Risk Assessment

### High Risks
1. **Memory corruption**: Improper C++/Swift interop could cause crashes
   - **Mitigation**: Extensive testing, AddressSanitizer, ThreadSanitizer

2. **Performance regression**: C++ implementation might not be faster
   - **Mitigation**: Benchmark before committing, keep Swift version as fallback

3. **Platform issues**: C++ atomics might behave differently on different Apple Silicon chips
   - **Mitigation**: Test on M1, M2, M3 if possible

### Medium Risks
1. **Build complexity**: C++ adds build system complexity
   - **Mitigation**: Document build settings clearly

2. **Maintenance burden**: Team needs C++ expertise
   - **Mitigation**: Comprehensive documentation, code comments

### Low Risks
1. **Compatibility**: C++17 is well-supported on modern macOS
2. **Dependencies**: No external C++ libraries needed (stdlib only)

---

## Code Review Checklist

### CircularBuffer Review
- [ ] Lock-free correctness verified
- [ ] Memory ordering is appropriate (relaxed vs acquire/release)
- [ ] Cache line alignment correct (no false sharing)
- [ ] Wrap-around logic handles all edge cases
- [ ] No undefined behavior (signed overflow, etc.)
- [ ] Memory leaks checked (Instruments Leaks tool)

### Audio Callbacks Review
- [ ] Zero allocations in callback path
- [ ] No exceptions thrown
- [ ] Error handling is graceful
- [ ] Buffer sizes validated before use
- [ ] Thread safety verified (ThreadSanitizer)
- [ ] HRIR bridge function is safe

---

## Documentation Updates

After successful migration, update:

1. **CLAUDE.md**: Add C++ interop patterns and build requirements
2. **BUILD_INSTRUCTIONS.md**: Add C++ compilation steps
3. **README.md**: Note performance improvements
4. **Code comments**: Document all C++ bridge functions
5. **Architecture diagrams**: Update to show C++ components

---

## Future Optimization Opportunities

After Phases 1-2 are complete and stable:

### Phase 3 (Optional): ConvolutionEngine Migration
- Only if C++ beats Accelerate (unlikely)
- Use ARM NEON intrinsics
- Custom FFT implementation

### Phase 4 (Optional): SIMD Optimizations
- Vectorize multi-channel mixing
- SIMD-optimized interleaving/deinterleaving
- Batch processing optimizations

---

## Questions to Resolve Before Starting

1. **Do we have M1/M2/M3 devices for testing?**
2. **What's the acceptable risk level?** (This touches critical audio path)
3. **Who has C++ expertise for code review?**
4. **What's the rollback deadline?** (If issues found, how quickly must we revert?)
5. **Is current performance actually a problem?** (Measure before optimizing)

---

## Conclusion

This migration plan provides a systematic approach to moving performance-critical components to C++. The two-phase approach (CircularBuffer first, callbacks second) allows for incremental validation and reduces risk.

**Key principle**: Measure, migrate, measure again. If C++ isn't faster, keep the Swift version.
