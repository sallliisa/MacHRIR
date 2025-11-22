# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MacHRIR is a macOS system-wide HRIR (Head-Related Impulse Response) binauralizer application that provides spatial audio processing through headphones. It uses CoreAudio to route audio from any input device through HRIR convolution to any output device, without changing system defaults. Similar to HeSuVi but designed specifically for macOS.

**Key Technologies**: Swift, CoreAudio, SwiftUI, Accelerate framework (FFT convolution)

## Build Commands

### Building
```bash
# Build debug version
xcodebuild -scheme MacHRIR -configuration Debug build

# Build release version
xcodebuild -scheme MacHRIR -configuration Release build

# Build and run from Xcode (recommended)
open MacHRIR.xcodeproj
# Then press ⌘R
```

### Build Artifacts
- Debug: `~/Library/Developer/Xcode/DerivedData/MacHRIR-*/Build/Products/Debug/MacHRIR.app`
- Release: `~/Library/Developer/Xcode/DerivedData/MacHRIR-*/Build/Products/Release/MacHRIR.app`

### Requirements
- macOS 12.0+
- Apple Silicon (ARM64)
- Xcode 14.0+
- **NSMicrophoneUsageDescription** must be set in Info.plist

## Architecture

### Critical Design Constraint: CoreAudio Only

**DO NOT use AVAudioEngine** for device selection. AVAudioEngine cannot select independent input/output devices on macOS. This project uses **separate CoreAudio Audio Units** for input and output. See `PASSTHROUGH_SPEC.md` for detailed rationale.

### Audio Flow

```
Input Device → Input Audio Unit (HAL) → Input Callback → Circular Buffer
                                                              ↓
Output Callback ← Output Audio Unit (HAL) ← Output Device ← Multi-channel HRIR Convolution
```

### Core Components

#### 1. AudioGraphManager.swift
Manages dual CoreAudio units for independent input/output device selection.

**Key features**:
- Separate `AudioUnit` instances for input and output (both `kAudioUnitSubType_HALOutput`)
- Non-interleaved (planar) audio format (macOS default)
- Thread-safe circular buffer decouples input/output clock domains
- Multi-channel support (up to 16 channels)
- Pre-allocated buffers for real-time processing (zero allocation in callbacks)

**Critical implementation details**:
- Input unit: Enable I/O on element 1 (input), disable on element 0 (output)
- Output unit: Default configuration (element 0)
- Device must be set BEFORE stream format
- AudioBufferList must be properly sized for variable-length array: `MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size`

#### 2. HRIRManager.swift
Manages HRIR presets and multi-channel binaural rendering.

**Architecture**:
- `VirtualSpeakerRenderer`: Represents one virtual speaker with two `ConvolutionEngine` instances (left/right ear)
- One renderer per input channel
- Processing uses **accumulation**: each channel's convolution is added to the stereo output

**Processing flow** (for N input channels):
```swift
// Zero output buffers
leftOutput = [0, 0, ..., 0]
rightOutput = [0, 0, ..., 0]

// Accumulate each virtual speaker's contribution
for each inputChannel:
    renderer = renderers[inputChannel]
    renderer.convolverLeftEar.processAndAccumulate(input, &leftOutput)
    renderer.convolverRightEar.processAndAccumulate(input, &rightOutput)
```

#### 3. ConvolutionEngine.swift
Implements **Uniform Partitioned Overlap-Save (UPOLS)** FFT convolution using Accelerate.

**Key method**: `processAndAccumulate(input:outputAccumulator:)`
- Adds convolution result to existing buffer (critical for multi-channel mixing)
- Zero-latency processing (block size: 512 samples)
- Supports long HRIRs via partitioning

#### 4. VirtualSpeaker.swift
Defines the abstraction layer between input channels and HRIR data.

**Key types**:
- `VirtualSpeaker`: Enum of speaker positions (FL, FR, FC, LFE, BL, BR, SL, SR, TFL, TFR, TBL, TBR)
- `InputLayout`: Defines what each input channel represents (e.g., `[FL, FR, FC, LFE, BL, BR, SL, SR]` for 7.1)
- `HRIRChannelMap`: Maps virtual speakers to HRIR WAV channel indices

**Supported HRIR mapping formats**:
1. **Interleaved Pairs** (HeSuVi standard): Ch0=FL_L, Ch1=FL_R, Ch2=FR_L, Ch3=FR_R, ...
2. **Split Blocks**: Ch0-N=All Left Ears, Ch(N+1)-2N=All Right Ears
3. **Custom**: HeSuVi mix.txt format parsing

#### 5. CircularBuffer.swift
Thread-safe ring buffer (65KB) with NSLock for clock drift tolerance between independent devices.

### Audio Format Specifications

**Format**: Non-interleaved (planar), 32-bit float, native sample rate
```swift
AudioStreamBasicDescription(
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat |
                  kAudioFormatFlagIsPacked |
                  kAudioFormatFlagIsNonInterleaved,
    mBitsPerChannel: 32,
    // mChannelsPerFrame: varies by device
    // mSampleRate: varies by device
)
```

**Non-interleaved layout**:
- `mNumberBuffers = channelCount`
- Each buffer: `mNumberChannels = 1`
- Channel data is NOT interleaved in memory

## Multi-Channel HRIR Processing

### Channel Count Requirements
For N input channels, HRIR file must have 2×N channels (one pair per virtual speaker).

**Examples**:
- Stereo (2.0): 4 HRIR channels
- 5.1 Surround: 12 HRIR channels
- 7.1 Surround: 16 HRIR channels
- 7.1.4 Atmos: 24 HRIR channels

### Auto-Detection
`InputLayout.detect(channelCount:)` automatically maps common channel counts:
- 2 → Stereo
- 6 → 5.1
- 8 → 7.1
- 12 → 7.1.4

### Custom Layouts
Users can provide custom HeSuVi mix.txt files for non-standard HRIR mappings.

## Real-Time Callback Constraints

**NEVER do these in audio callbacks** (`inputRenderCallback`, `renderCallback`):
- Memory allocation/deallocation
- Swift runtime operations (prefer C-like code)
- Objective-C message sends
- Locks (except minimal circular buffer lock)
- Logging/debugging (use atomic flags instead)

**ALWAYS**:
- Pre-allocate all buffers during initialization
- Use `UnsafeMutablePointer` for channel buffers
- Use `defer` blocks to ensure cleanup in setup code

## Common Implementation Patterns

### Setting Audio Device on Audio Unit
```swift
// MUST set device BEFORE format
var deviceID: AudioDeviceID = selectedDevice.id
AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

### Allocating AudioBufferList for Input Callback
```swift
let bufferListSize = MemoryLayout<AudioBufferList>.size +
                     max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size

let bufferListPointer = UnsafeMutableRawPointer.allocate(
    byteCount: bufferListSize,
    alignment: MemoryLayout<AudioBufferList>.alignment
)
defer { bufferListPointer.deallocate() }

let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)
```

### Activating Multi-Channel HRIR
```swift
let layout = InputLayout.detect(channelCount: 8)  // Auto-detect 7.1
let map = HRIRChannelMap.interleavedPairs(speakers: layout.channels)

hrirManager.activatePreset(
    preset,
    targetSampleRate: 48000,
    inputLayout: layout,
    hrirMap: map
)
```

## File Locations

### Application Support
- Presets: `~/Library/Application Support/MacHRIR/presets/`
- Settings: `UserDefaults` (standard domain)

### Source Structure
```
MacHRIR/
├── MacHRIRApp.swift           # App entry point
├── MenuBarManager.swift       # Menu bar UI (if menubar mode)
├── AudioGraphManager.swift    # CoreAudio dual-unit management
├── CircularBuffer.swift       # Ring buffer
├── AudioDevice.swift          # Device enumeration
├── ConvolutionEngine.swift    # FFT convolution (Accelerate)
├── FFTSetupManager.swift      # Singleton FFT setup cache
├── HRIRManager.swift          # Preset & multi-channel rendering
├── VirtualSpeaker.swift       # Speaker abstraction & mapping
├── WAVLoader.swift            # WAV file parsing
├── Resampler.swift            # Sample rate conversion
├── SettingsManager.swift      # Settings persistence
└── Assets.xcassets/          # App icons/resources
```

## Common Errors and Solutions

### Error -10851 (kAudioUnitErr_InvalidPropertyValue)
- **Cause**: Setting device property at wrong time
- **Fix**: Set device BEFORE stream format, BEFORE `AudioUnitInitialize()`

### Error -50 (kAudio_ParamError) / "mNumberBuffers mismatch"
- **Cause**: Buffer list doesn't match non-interleaved format
- **Fix**: Use `mNumberBuffers = channelCount` with each buffer having `mNumberChannels = 1`

### Memory access errors in callbacks
- **Cause**: Improper AudioBufferList allocation
- **Fix**: Calculate size correctly for variable-length array (see pattern above)

### No audio output
- Check circular buffer is not underrunning
- Verify sample rates match between input/output devices
- Confirm correct element numbers (1=input, 0=output)
- Check Console.app for CoreAudio errors

### HRIR file fails to load
- Verify channel count = InputChannels × 2
- Check WAV format (must be valid WAV, 16/24/32-bit)
- Ensure mapping format matches file structure

## Performance Targets

- **Latency**: <10ms end-to-end (512 samples @ 48kHz)
- **CPU**: <10% on Apple M1/M2 (single thread)
- **Memory**: ~2-3MB for 7.1 (16 convolution engines)

## Documentation Files

- **PASSTHROUGH_SPEC.md**: Why AVAudioEngine doesn't work, detailed CoreAudio implementation
- **MULTI_CHANNEL_ARCHITECTURE.md**: Complete multi-channel rendering architecture
- **QUICK_REFERENCE.md**: Formulas and code snippets for HRIR processing
- **BUILD_INSTRUCTIONS.md**: Detailed build steps and prerequisites
- **TROUBLESHOOTING.md**: Common issues and solutions
- **README.md**: User-facing documentation

## Development Notes

### Testing a Change
1. Make code changes
2. Build in Xcode (⌘R)
3. Test with real audio (play music/video)
4. Check level meters show activity
5. Verify no glitches/dropouts
6. Check Console.app for errors

### Adding New HRIR Mapping Format
1. Add parsing logic to `HRIRChannelMap` in `VirtualSpeaker.swift`
2. Update `activatePreset()` in `HRIRManager.swift` to support auto-detection
3. Test with sample HRIR file

### Debugging Audio Issues
- Enable debug logging (avoid in callbacks)
- Check `AudioUnitRender()` return status
- Verify channel counts at each stage
- Monitor circular buffer fill level
- Use Instruments for CPU/memory profiling
