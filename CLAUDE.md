# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MacHRIR is a macOS menu bar application that provides system-wide HRIR (Head-Related Impulse Response) spatial audio processing through headphones. It uses CoreAudio to route audio from any input device through HRIR convolution to any output device, without changing system defaults. Similar to HeSuVi but designed specifically for macOS.

**Key Technologies**: Swift, CoreAudio, SwiftUI (minimal), Accelerate framework (FFT convolution)

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

### Application Structure

**Menu Bar Application**: MacHRIR runs as a menu bar app (status item in menu bar) with no main window. The UI is entirely menu-based.

**Entry Point Flow**:
```
MacHRIRApp.swift (@main)
    ↓
AppDelegate.swift (NSApplicationDelegate)
    ↓
MenuBarManager.swift (NSStatusItem + NSMenu)
    ↓
AudioGraphManager + HRIRManager + AudioDeviceManager
```

### Critical Design Constraint: CoreAudio Only

**DO NOT use AVAudioEngine** for device selection. AVAudioEngine cannot select independent input/output devices on macOS. This project uses **separate CoreAudio Audio Units** for input and output.

### Audio Flow

```
Input Device → Input Audio Unit (HAL) → Input Callback → Circular Buffer
                                                              ↓
Output Callback ← Output Audio Unit (HAL) ← Output Device ← Multi-channel HRIR Convolution
```

### Core Components

#### 1. MenuBarManager.swift
Manages the menu bar UI and coordinates all managers.

**Key features**:
- Creates NSStatusItem with waveform icon
- Builds dynamic menu with device selection, preset management, controls
- Coordinates AudioGraphManager, HRIRManager, AudioDeviceManager, SettingsManager
- Persists user settings (selected devices, presets, convolution state)
- Handles menu updates and user interactions

#### 2. AudioGraphManager.swift
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

**Recent optimizations**:
- All buffers pre-allocated in init() to avoid malloc in audio callbacks
- Uses `UnsafeMutablePointer` for zero-overhead channel buffer access
- Buffering state to prevent underruns on startup

#### 3. HRIRManager.swift
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

#### 4. ConvolutionEngine.swift
Implements **Uniform Partitioned Overlap-Save (UPOLS)** FFT convolution using Accelerate.

**Key method**: `processAndAccumulate(input:outputAccumulator:)`
- Adds convolution result to existing buffer (critical for multi-channel mixing)
- Zero-latency processing (block size: 512 samples)
- Supports long HRIRs via partitioning

**Optimization**: Uses `FFTSetupManager` singleton to cache FFT setup objects and avoid redundant vDSP_create_fftsetup() calls.

#### 5. FFTSetupManager.swift
Singleton that caches FFT setup objects to reduce memory allocations.

**Purpose**: vDSP_create_fftsetup() can be expensive. This manager ensures each FFT size only creates one setup instance, shared across all ConvolutionEngine instances.

#### 6. VirtualSpeaker.swift
Defines the abstraction layer between input channels and HRIR data.

**Key types**:
- `VirtualSpeaker`: Enum of speaker positions (FL, FR, FC, LFE, BL, BR, SL, SR, TFL, TFR, TBL, TBR)
- `InputLayout`: Defines what each input channel represents (e.g., `[FL, FR, FC, LFE, BL, BR, SL, SR]` for 7.1)
- `HRIRChannelMap`: Maps virtual speakers to HRIR WAV channel indices

**Supported HRIR mapping formats**:
1. **Interleaved Pairs** (HeSuVi standard): Ch0=FL_L, Ch1=FL_R, Ch2=FR_L, Ch3=FR_R, ...
2. **Split Blocks**: Ch0-N=All Left Ears, Ch(N+1)-2N=All Right Ears
3. **Custom**: HeSuVi mix.txt format parsing

#### 7. CircularBuffer.swift
Thread-safe ring buffer (65KB) with NSLock for clock drift tolerance between independent devices.

**Note**: CPP_MIGRATION_PLAN.md documents a planned migration to lock-free C++ implementation, but current version uses NSLock.

#### 8. AudioDevice.swift
Enumerates and manages CoreAudio devices.

#### 9. SettingsManager.swift
Persists user preferences using UserDefaults (device selections, preset selections, convolution state).

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
- Swift runtime operations that trigger allocations
- Objective-C message sends
- Locks (except minimal circular buffer lock)
- Logging/debugging (use atomic flags instead)

**ALWAYS**:
- Pre-allocate all buffers during initialization (see AudioGraphManager.init())
- Use `UnsafeMutablePointer` for channel buffers
- Use `defer` blocks to ensure cleanup in setup code
- Zero out buffers using memset or pointer initialization

**Recent fixes**: All transient mallocs in audio callbacks have been eliminated by pre-allocating AudioBufferList and channel buffers in AudioGraphManager.init().

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

### Adding Menu Items in MenuBarManager
```swift
// Device selection submenu
let inputDeviceMenu = NSMenu()
for device in deviceManager.inputDevices {
    let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = device
    item.state = (device.id == audioManager.inputDevice?.id) ? .on : .off
    inputDeviceMenu.addItem(item)
}
```

## File Locations

### Application Support
- Presets: `~/Library/Application Support/MacHRIR/presets/`
- Settings: `UserDefaults` (standard domain)

### Source Structure
```
MacHRIR/
├── MacHRIRApp.swift           # App entry point
├── AppDelegate.swift          # App delegate (creates MenuBarManager)
├── MenuBarManager.swift       # Menu bar UI and coordinator
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

### Excessive transient mallocs in audio callbacks
- **Cause**: Not pre-allocating buffers, using Swift Arrays in callbacks
- **Fix**: Pre-allocate all buffers in init(), use UnsafeMutablePointer instead of Arrays

### No audio output
- Check circular buffer is not underrunning
- Verify sample rates match between input/output devices
- Confirm correct element numbers (1=input, 0=output)
- Check Console.app for CoreAudio errors
- Verify buffering state allows processing to start

### HRIR file fails to load
- Verify channel count = InputChannels × 2
- Check WAV format (must be valid WAV, 16/24/32-bit)
- Ensure mapping format matches file structure

## Performance Targets

- **Latency**: <10ms end-to-end (512 samples @ 48kHz)
- **CPU**: <10% on Apple M1/M2 (single thread)
- **Memory**: ~2-3MB for 7.1 (16 convolution engines)

## Development Notes

### Testing a Change
1. Make code changes
2. Build in Xcode (⌘R)
3. App appears in menu bar (waveform icon)
4. Select input device (e.g., BlackHole 2ch)
5. Select output device (e.g., headphones)
6. Add/select HRIR preset
7. Enable convolution
8. Click Start
9. Play audio and verify processing works
10. Check Console.app for errors

### Adding New Device Features
When modifying device selection or audio unit setup:
1. Always stop audio before reconfiguring
2. Dispose and recreate audio units if changing devices
3. Update channel counts before reinitializing
4. Save settings via SettingsManager

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
- Check Console.app for CoreAudio errors
- Verify buffering state transitions correctly

### Memory Management Best Practices
- All audio callback buffers MUST be pre-allocated in init()
- Use `UnsafeMutablePointer` instead of Swift Arrays in callbacks
- Use memset for zeroing buffers
- Check with Instruments Allocations tool to verify zero malloc in callbacks
- Use FFTSetupManager to avoid redundant FFT setup allocations

## Future Work

### Planned C++ Migration
See `CPP_MIGRATION_PLAN.md` for detailed plan to migrate performance-critical components:
1. **Phase 1**: Lock-free CircularBuffer (C++ atomics instead of NSLock)
2. **Phase 2**: Audio callbacks in pure C++ (eliminate Swift runtime overhead)

This migration is planned but not yet implemented. Current code is pure Swift.

### Potential Features
- System aggregate device support (current branch: system_aggregate_device)
- Automatic device reconnection on wake from sleep
- Preset auto-switching based on input channel count
- EQ integration (see HeSuVi_Reference/eq/ for presets)
