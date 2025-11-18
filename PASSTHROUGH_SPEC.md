# macOS Audio Passthrough Specification

## Overview

This document provides a complete specification for implementing independent audio device selection on macOS without changing system defaults. This allows an application to route audio from any selected input device to any selected output device, regardless of the system's default audio settings.

## Key Problem: AVAudioEngine Limitations

**CRITICAL**: `AVAudioEngine` on macOS **cannot** be used for independent input/output device selection.

### Why AVAudioEngine Doesn't Work

According to Apple's documentation and developer forums:

1. **Single Aggregate Device Limitation**: An AVAudioEngine can only be assigned to a single aggregate device (a device with both input and output channels)
2. **No Separate Device Support**: You cannot set different input and output devices on AVAudioEngine
3. **Device Setting Errors**: Attempting to use `kAudioOutputUnitProperty_CurrentDevice` on AVAudioEngine's nodes results in error -10851 (kAudioUnitErr_InvalidPropertyValue)
4. **System Default Changes Required**: AVAudioEngine primarily uses system default devices

### The Solution: CoreAudio with Separate Audio Units

The only reliable way to achieve independent input/output device selection is to use **CoreAudio directly** with separate Audio Unit instances.

## Architecture

### High-Level Design

```
Input Device → Input Audio Unit → Input Callback → Circular Buffer → Output Callback → Output Audio Unit → Output Device
```

### Components

1. **Input Audio Unit** (`kAudioUnitSubType_HALOutput`)
   - HAL (Hardware Abstraction Layer) output unit configured for input
   - Set to specific input device via `kAudioOutputUnitProperty_CurrentDevice`
   - Captures audio via input callback

2. **Output Audio Unit** (`kAudioUnitSubType_HALOutput`)
   - HAL output unit configured for output
   - Set to specific output device via `kAudioOutputUnitProperty_CurrentDevice`
   - Renders audio via output callback

3. **Circular Buffer**
   - Thread-safe ring buffer
   - Decouples input and output (handles clock differences between devices)
   - Size: 65536 bytes (provides ~1.5 seconds buffer at 48kHz stereo)

4. **Audio Callbacks**
   - Input callback: Pulls audio from input device, writes to circular buffer
   - Output callback: Reads from circular buffer, provides to output device

## Critical Implementation Details

### 1. Audio Format: Non-Interleaved

macOS audio devices use **non-interleaved (planar)** audio format by default.

**Non-Interleaved Format**:
- Each channel has its own separate buffer
- For stereo: `mNumberBuffers = 2`, each with `mNumberChannels = 1`
- Channel 0 buffer contains all left channel samples
- Channel 1 buffer contains all right channel samples

**Format Specification**:
```swift
AudioStreamBasicDescription(
    mSampleRate: 48000.0,              // Match device sample rate
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat |
                  kAudioFormatFlagIsPacked |
                  kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4,                 // 4 bytes per float
    mFramesPerPacket: 1,
    mBytesPerFrame: 4,                  // 4 bytes per float
    mChannelsPerFrame: 2,               // Stereo
    mBitsPerChannel: 32,                // 32-bit float
    mReserved: 0
)
```

### 2. Input Audio Unit Setup

**Critical Step Order**:

```swift
// 1. Create component
var component = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
)

// 2. Find and instantiate
let comp = AudioComponentFindNext(nil, &component)
var unit: AudioUnit?
AudioComponentInstanceNew(comp, &unit)

// 3. Enable input (element 1)
var enableIO: UInt32 = 1
AudioUnitSetProperty(
    unit,
    kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Input,
    1,  // Input element
    &enableIO,
    UInt32(MemoryLayout<UInt32>.size)
)

// 4. Disable output (element 0)
var disableIO: UInt32 = 0
AudioUnitSetProperty(
    unit,
    kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Output,
    0,  // Output element
    &disableIO,
    UInt32(MemoryLayout<UInt32>.size)
)

// 5. Set the device BEFORE setting format
var deviceID: AudioDeviceID = selectedDeviceID
AudioUnitSetProperty(
    unit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)

// 6. Get device's format
var deviceFormat = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(
    unit,
    kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input,
    1,  // Input element
    &deviceFormat,
    &size
)

// 7. Set output format (what the callback receives)
// Use device's sample rate and channel count
var streamFormat = AudioStreamBasicDescription(
    mSampleRate: deviceFormat.mSampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat |
                  kAudioFormatFlagIsPacked |
                  kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4,
    mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
    mBitsPerChannel: 32,
    mReserved: 0
)

AudioUnitSetProperty(
    unit,
    kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output,
    1,  // Input element (output of the input scope)
    &streamFormat,
    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
)

// 8. Set input callback
var callback = AURenderCallbackStruct(
    inputProc: inputRenderCallback,
    inputProcRefCon: contextPointer
)
AudioUnitSetProperty(
    unit,
    kAudioOutputUnitProperty_SetInputCallback,
    kAudioUnitScope_Global,
    0,
    &callback,
    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
)

// 9. Initialize
AudioUnitInitialize(unit)

// 10. Start
AudioOutputUnitStart(unit)
```

### 3. Output Audio Unit Setup

**Critical Step Order**:

```swift
// 1-2. Create component (same as input)

// 3. Set device BEFORE format
var deviceID: AudioDeviceID = selectedDeviceID
AudioUnitSetProperty(
    unit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)

// 4. Get device format
var deviceFormat = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(
    unit,
    kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output,
    0,  // Output element
    &deviceFormat,
    &size
)

// 5. Set input format (what the callback provides)
var streamFormat = AudioStreamBasicDescription(
    mSampleRate: deviceFormat.mSampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat |
                  kAudioFormatFlagIsPacked |
                  kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4,
    mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
    mBitsPerChannel: 32,
    mReserved: 0
)

AudioUnitSetProperty(
    unit,
    kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input,
    0,  // Output element (input to the output scope)
    &streamFormat,
    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
)

// 6. Set render callback
var callback = AURenderCallbackStruct(
    inputProc: renderCallback,
    inputProcRefCon: contextPointer
)
AudioUnitSetProperty(
    unit,
    kAudioUnitProperty_SetRenderCallback,
    kAudioUnitScope_Input,
    0,
    &callback,
    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
)

// 7. Initialize
AudioUnitInitialize(unit)

// 8. Start
AudioOutputUnitStart(unit)
```

### 4. Input Callback Implementation

**CRITICAL**: Proper AudioBufferList allocation for variable-length array

```swift
private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // 1. Get manager reference
    let manager = Unmanaged<YourManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let inputUnit = manager.inputUnit else { return noErr }

    // 2. Get stream format to know channel count
    var streamFormat = AudioStreamBasicDescription()
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    let formatStatus = AudioUnitGetProperty(
        inputUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &streamFormat,
        &propertySize
    )

    guard formatStatus == noErr else { return formatStatus }

    let channelCount = max(1, Int(streamFormat.mChannelsPerFrame))
    let bytesPerChannel = Int(inNumberFrames) * 4  // 4 bytes per Float32

    // 3. Allocate AudioBufferList with proper size for variable-length array
    // AudioBufferList has: UInt32 + [AudioBuffer]
    // For N channels, need space for N AudioBuffers
    let bufferListSize = MemoryLayout<AudioBufferList>.size +
                         max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size

    let bufferListPointer = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }

    let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)

    // 4. Allocate data buffers (one per channel for non-interleaved)
    var audioBuffers: [UnsafeMutableRawPointer] = []
    for _ in 0..<channelCount {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerChannel,
            alignment: 16
        )
        audioBuffers.append(buffer)
    }

    defer {
        for buffer in audioBuffers {
            buffer.deallocate()
        }
    }

    // 5. Set up the AudioBuffer structures
    let audioBuffersPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for (index, buffer) in audioBuffers.enumerated() {
        audioBuffersPtr[index].mNumberChannels = 1  // Non-interleaved
        audioBuffersPtr[index].mDataByteSize = UInt32(bytesPerChannel)
        audioBuffersPtr[index].mData = buffer
    }

    // 6. Pull audio from input device
    let status = AudioUnitRender(
        inputUnit,
        ioActionFlags,
        inTimeStamp,
        1,  // Input element
        inNumberFrames,
        audioBufferList
    )

    // 7. Write to circular buffer (if successful)
    if status == noErr {
        for buffer in audioBuffers {
            manager.circularBuffer.write(data: buffer, size: bytesPerChannel)
        }
    }

    return noErr
}
```

### 5. Output Callback Implementation

```swift
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<YourManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let bufferList = ioData else { return noErr }

    // Access the buffer list
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let channelCount = Int(bufferList.pointee.mNumberBuffers)

    // Read each channel from circular buffer
    for i in 0..<channelCount {
        let buffer = buffers[i]
        let byteSize = Int(buffer.mDataByteSize)

        if let data = buffer.mData {
            // Read from circular buffer
            let bytesRead = manager.circularBuffer.read(into: data, size: byteSize)

            // Fill remaining with silence if not enough data
            if bytesRead < byteSize {
                memset(data.advanced(by: bytesRead), 0, byteSize - bytesRead)
            }
        }
    }

    return noErr
}
```

### 6. Circular Buffer Implementation

Thread-safe ring buffer to handle clock differences between devices:

```swift
class CircularBuffer {
    private var buffer: UnsafeMutableRawPointer
    private var size: Int
    private var writeIndex = 0
    private var readIndex = 0
    private let lock = NSLock()

    init(size: Int) {
        self.size = size
        self.buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<Float>.alignment
        )
    }

    deinit {
        buffer.deallocate()
    }

    func write(data: UnsafeRawPointer, size: Int) {
        lock.lock()
        defer { lock.unlock() }

        let available = availableWrite()
        let toWrite = min(size, available)

        if toWrite == 0 { return }

        // Handle wrap-around
        let firstChunk = min(toWrite, self.size - writeIndex)
        memcpy(buffer.advanced(by: writeIndex), data, firstChunk)

        if firstChunk < toWrite {
            memcpy(buffer, data.advanced(by: firstChunk), toWrite - firstChunk)
        }

        writeIndex = (writeIndex + toWrite) % self.size
    }

    func read(into data: UnsafeMutableRawPointer, size: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let available = availableRead()
        let toRead = min(size, available)

        if toRead == 0 { return 0 }

        // Handle wrap-around
        let firstChunk = min(toRead, self.size - readIndex)
        memcpy(data, buffer.advanced(by: readIndex), firstChunk)

        if firstChunk < toRead {
            memcpy(data.advanced(by: firstChunk), buffer, toRead - firstChunk)
        }

        readIndex = (readIndex + toRead) % self.size

        return toRead
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        writeIndex = 0
        readIndex = 0
    }

    private func availableWrite() -> Int {
        if writeIndex >= readIndex {
            return size - (writeIndex - readIndex) - 1
        } else {
            return readIndex - writeIndex - 1
        }
    }

    private func availableRead() -> Int {
        if writeIndex >= readIndex {
            return writeIndex - readIndex
        } else {
            return size - (readIndex - writeIndex)
        }
    }
}
```

### 7. Device Enumeration

Using AudioKit for convenience:

```swift
// Get input devices
let inputDevices = AudioEngine.inputDevices

// Get output devices
let outputDevices = AudioEngine.outputDevices

// Each Device has:
// - deviceID: AudioDeviceID (used for kAudioOutputUnitProperty_CurrentDevice)
// - name: String (display to user)
```

Or using CoreAudio directly:

```swift
func getAudioDevices() -> [AudioDeviceID] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &dataSize
    )

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: deviceCount)

    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &dataSize,
        &devices
    )

    return devices
}
```

## Common Pitfalls and Solutions

### 1. Error -10851 (kAudioUnitErr_InvalidPropertyValue)

**Cause**: Trying to set device property at wrong time or on wrong scope/element

**Solution**:
- Set device BEFORE setting stream format
- Set device BEFORE calling AudioUnitInitialize()
- Use correct scope/element (Global/0 for device property)

### 2. Error -50 (kAudio_ParamError) / "mNumberBuffers mismatch"

**Cause**: Buffer list doesn't match audio format (interleaved vs non-interleaved)

**Solution**:
- Use non-interleaved format with `mNumberBuffers = channelCount`
- Each buffer has `mNumberChannels = 1`
- Properly allocate AudioBufferList for variable-length array

### 3. Memory Read Failed / Crash in Callback

**Cause**: Improper AudioBufferList allocation or dangling pointers

**Solution**:
- Calculate correct size: `MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size`
- Use `UnsafeMutableRawPointer.allocate()` with proper alignment
- Use `defer` blocks to ensure cleanup
- Never access `mBuffers` beyond allocated count

### 4. No Audio / Silence

**Causes**:
- Circular buffer underrun
- Format mismatch between input and output
- Incorrect element numbers in properties

**Solutions**:
- Check console logs for AudioUnit errors
- Verify sample rates match
- Verify channel counts match
- Use correct element: 1 for input, 0 for output
- Increase circular buffer size

### 5. Audio Glitches / Dropouts

**Causes**:
- Circular buffer too small
- Thread contention in circular buffer
- Different sample rates between devices

**Solutions**:
- Increase circular buffer size (65536 bytes minimum)
- Use NSLock in circular buffer
- Match sample rates or implement sample rate conversion

## Testing Checklist

- [ ] Select different input device from system default
- [ ] Select different output device from system default
- [ ] Verify system defaults don't change (check System Settings)
- [ ] Test mono input device
- [ ] Test stereo input device
- [ ] Test multi-channel devices (if available)
- [ ] Test device switching while active
- [ ] Test starting/stopping multiple times
- [ ] Check for memory leaks (Instruments)
- [ ] Test with different sample rates
- [ ] Verify audio quality (no distortion, dropouts, or glitches)

## Required Permissions

Add to Info.plist:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app requires microphone access to pass through audio from the selected input device.</string>
```

## Performance Considerations

1. **Callbacks run on real-time audio thread**
   - No allocations in callbacks (pre-allocate all buffers)
   - No locks except minimal circular buffer lock
   - No Objective-C message sends
   - No Swift runtime operations (use simple C-like code)

2. **Buffer sizes**
   - Typical: 512 frames at 48kHz = ~10ms latency
   - Circular buffer: 65536 bytes = ~1.5 seconds at 48kHz stereo

3. **Clock drift**
   - Input and output devices have independent clocks
   - Circular buffer absorbs short-term drift
   - Long-term drift may require sample rate conversion

## References

- [Apple Core Audio Documentation](https://developer.apple.com/documentation/coreaudio)
- [Audio Unit Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitProgrammingGuide/)
- [Stack Overflow: AVAudioEngine device selection limitations](https://stackoverflow.com/questions/61827898/)
- [AudioKit GitHub Issue #2130](https://github.com/AudioKit/AudioKit/issues/2130)

## Version History

- v1.0 (2025-01-18): Initial specification based on working implementation
