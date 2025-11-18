# macOS System-Wide HRIR DSP — Technical Specification

## Overview
This document specifies the design and implementation requirements for a macOS application that provides system-wide HRIR-based convolution, similar to HeSuVi but for macOS. The solution uses a virtual audio device to capture system audio, processes it through a standalone DSP engine that applies HRIR convolution, and outputs the processed stereo signal to a user-selected physical device.

---

## Goals
- Apply HRIR/HRTF convolution to all system audio.
- Provide system-wide spatial audio through headphones.
- Create a fully open-source solution (MIT or Apache-2).
- Keep latency under 10 ms end-to-end.
- Provide a clean, simple UI.

---

## Architecture Summary
System Audio
- Virtual Audio Device (BlackHole)
- DSP Application (HRIR convolution)
- Physical Output Device (headphones)

---

## Components

### 1. Virtual Audio Device
- **Default input device: BlackHole 2ch**
- Implement using either:
  - A custom Audio Server Plugin (ASP), or
  - An existing open-source driver (e.g., BlackHole).
- Must appear in System Settings → Sound under "Output."
- Must support:
  - 2-channel audio
  - 44100 Hz and 48000 Hz
  - Low-latency transfer to the DSP app
- **Users must be able to switch input devices** from the application UI.

### 2. DSP Processing Engine

**CRITICAL**: `AVAudioEngine` **cannot** be used for independent input/output device selection on macOS.

#### Architecture: CoreAudio with Separate Audio Units

Due to AVAudioEngine limitations (single aggregate device, no separate device support), the audio engine must be implemented using **CoreAudio directly** with separate Audio Unit instances:

**Audio Flow**:
```
Input Device → Input Audio Unit → Input Callback → Circular Buffer → Processing → Output Callback → Output Audio Unit → Output Device
```

**Components**:
- **Input Audio Unit** (`kAudioUnitSubType_HALOutput` configured for input)
  - Set to specific input device via `kAudioOutputUnitProperty_CurrentDevice`
  - Captures audio via input callback
  - Element 1 enabled for input, element 0 disabled for output

- **Output Audio Unit** (`kAudioUnitSubType_HALOutput` configured for output)
  - Set to specific output device via `kAudioOutputUnitProperty_CurrentDevice`
  - Renders audio via output callback
  - Standard output configuration

- **Circular Buffer** (Thread-safe ring buffer)
  - Decouples input and output (handles clock differences between devices)
  - Size: 65536 bytes minimum (provides ~1.5 seconds buffer at 48kHz stereo)
  - Thread-safe with NSLock for concurrent access

**Audio Format Requirements**:
- Must use **non-interleaved (planar)** format (macOS default)
- Format flags: `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved`
- For stereo: `mNumberBuffers = 2`, each with `mNumberChannels = 1`
- 32-bit float samples (4 bytes per sample)

**Sample Rate Management**:
- Input and output devices may have different sample rates
- Set audio unit format AFTER setting the device (device must be set first)
- Query device's native sample rate before setting stream format
- HRIRs must be resampled to match the processing sample rate (see HRIR Handling)
- Circular buffer absorbs short-term clock drift between devices

**DSP Processing**:
- Receives audio from input callback via circular buffer
- Processes audio in real time using HRIR convolution
- Outputs processed audio to output callback
- Must use a low-latency architecture:
  - Overlap-save FFT convolution
  - Avoid heap allocations inside the audio callback
  - Avoid locks inside the callback (except minimal circular buffer lock)
  - Pre-allocate all buffers during initialization

### 3. HRIR Handling
- Support loading HRIR sets from:
  - WAV impulse response files (single multi-channel WAV file per preset)
- **Must gracefully handle HRIR files with any number of channels:**
  - Stereo (2-channel)
  - 14-channel
  - Any other channel count
- **Multi-channel HRIR mapping to stereo output:**
  - For multi-channel HRIR files, use channels 0 and 1 as Left and Right respectively
  - Channels 0 and 1 are extracted and used for stereo convolution
  - Additional channels (2+) are ignored
  - If HRIR has only 1 channel, duplicate it for both L/R outputs
  - If HRIR has 0 channels or invalid channel count, show error
- **Sample rate handling:**
  - HRIR files may have different sample rates than the audio processing rate
  - HRIR must be resampled to match the current input/output sample rate during loading
  - Resampling occurs during HRIR preprocessing (before FFT conversion)
  - Use high-quality resampling algorithm (e.g., linear interpolation or sinc-based)
  - If resampling fails or HRIR sample rate is invalid, show detailed error message
- The app must detect the channel count and process the HRIR appropriately.
- Support multiple presets.
- Allow runtime switching.
- HRIR loader must preprocess IRs into FFT blocks for performance.

### 4. Output Device Routing
- Enumerate physical audio output devices using CoreAudio APIs.
- Allow the user to select an output device from the UI.
- Reconnect automatically if the device is disconnected.
- Must support:
  - Stereo output
  - Hot-swapping without crashing
  - Device sample rate changes

### 5. UI (SwiftUI)
- Device selection:
  - **Input device (selectable, defaults to BlackHole 2ch)**
  - Output device (selectable)
- HRIR preset selector
- Toggle: Convolution on/off
- **Input signal detection indicator:**
  - Must show whether there's signal or not from the input device
  - Visual indicator (e.g., icon, color change) when signal is present/absent
- **Level meters:**
  - Raw input audio level meter (before processing)
  - Processed output audio level meter (after HRIR convolution)
  - Meters should display RMS or peak levels
  - Visual representation (e.g., bar meters, waveform)
- Latency indicator
- Status indicators for:
  - "Engine running"
  - "Device disconnected"
  - "HRIR missing or invalid"

---

## Code Architecture

### Languages
- **C++** for DSP core
- **Swift** for macOS integration and UI (SwiftUI)
- **Bridging layer** via Swift-C++ interop or C wrapper

### Modules

#### AudioGraphManager
- **Must use CoreAudio with separate Audio Units** (NOT AVAudioEngine - see DSP Processing Engine section)
- Manages two separate Audio Unit instances:
  - Input Audio Unit (HAL output unit configured for input)
  - Output Audio Unit (HAL output unit configured for output)
- Handles device selection via `kAudioOutputUnitProperty_CurrentDevice`
- Implements audio callbacks:
  - Input callback: Pulls audio from input device, writes to circular buffer
  - Output callback: Reads from circular buffer (or processed audio), provides to output device
- Manages circular buffer for decoupling input/output
- Controls buffer sizes and stream formats (non-interleaved)
- **Critical setup order**:
  1. Create Audio Unit
  2. Enable/disable I/O on correct elements
  3. Set device BEFORE setting format
  4. Query device format
  5. Set stream format to match device
  6. Set callback
  7. Initialize and start

#### ConvolutionEngine
- Overlap-save FFT
- Handles:
  - Forward FFT
  - Complex multiplication
  - Inverse FFT
  - Overlap buffer management
- One engine per channel (L/R)

#### HRIRManager
- Loads HRIR datasets from multi-channel WAV files
- Extracts channels 0 and 1 from multi-channel HRIR files
- Resamples HRIR to match current processing sample rate
- Converts HRIR to frequency domain (FFT)
- Manages preset switching
- Validates HRIR files (channel count, sample rate, file format)

#### DeviceRouter
- Enumerates devices
- Handles routing changes
- Detects device availability
- Applies format changes

#### SettingsManager
- JSON-based config
- Saves:
  - Selected output device
  - HRIR preset
  - Convolution enabled/disabled
  - Buffer size
  - Sample rate preferences

---

## Implementation Details & Common Pitfalls

### AudioBufferList Allocation
**CRITICAL**: Proper allocation for variable-length array in callbacks:
- AudioBufferList has: `UInt32 mNumberBuffers` + `AudioBuffer mBuffers[1]` (variable-length array)
- For N channels, calculate size: `MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size`
- Use `UnsafeMutableRawPointer.allocate()` with proper alignment
- Allocate separate data buffers for each channel (non-interleaved)
- Use `defer` blocks to ensure cleanup
- Never access `mBuffers` beyond allocated count

### Input Callback Implementation Requirements
1. Get stream format to determine channel count
2. Calculate buffer sizes: `bytesPerChannel = frameCount * 4` (Float32)
3. Allocate AudioBufferList with correct size for variable-length array
4. Allocate data buffers (one per channel, 16-byte aligned)
5. Set up AudioBuffer structures (each with `mNumberChannels = 1` for non-interleaved)
6. Call `AudioUnitRender()` with element 1 (input element)
7. Write received audio to circular buffer
8. Clean up all allocated memory with defer blocks

### Output Callback Implementation Requirements
1. Access provided AudioBufferList from `ioData` parameter
2. Get channel count from `mNumberBuffers`
3. Read each channel from circular buffer (or processed audio)
4. Fill remaining with silence if insufficient data available
5. No memory allocation required (buffers provided by system)

### Common Errors and Solutions

**Error -10851 (kAudioUnitErr_InvalidPropertyValue)**:
- Cause: Setting device property at wrong time or on wrong scope/element
- Solution: Set device BEFORE setting stream format, BEFORE `AudioUnitInitialize()`, use scope Global/element 0

**Error -50 (kAudio_ParamError) / "mNumberBuffers mismatch"**:
- Cause: Buffer list doesn't match audio format (interleaved vs non-interleaved)
- Solution: Use non-interleaved format with `mNumberBuffers = channelCount`, each buffer has `mNumberChannels = 1`

**Memory Read Failed / Crash in Callback**:
- Cause: Improper AudioBufferList allocation or dangling pointers
- Solution: Calculate correct size including variable-length array, use proper alignment, use defer blocks

**No Audio / Silence**:
- Causes: Circular buffer underrun, format mismatch, incorrect element numbers
- Solutions: Check console logs, verify sample rates match, verify channel counts match, use correct element (1 for input, 0 for output)

**Audio Glitches / Dropouts**:
- Causes: Circular buffer too small, thread contention, different sample rates
- Solutions: Increase circular buffer size (65536 bytes minimum), use NSLock, match sample rates or implement SRC

### Circular Buffer Implementation Requirements
- Thread-safe ring buffer using NSLock
- Size: 65536 bytes minimum (adjustable based on latency requirements)
- Methods: `write()`, `read()`, `reset()`, `availableWrite()`, `availableRead()`
- Handle wrap-around correctly
- Return bytes read/written for underrun detection

### Device Enumeration
- Use CoreAudio APIs: `kAudioHardwarePropertyDevices`
- Or use AudioKit convenience methods: `AudioEngine.inputDevices`, `AudioEngine.outputDevices`
- Each device has `AudioDeviceID` (used for `kAudioOutputUnitProperty_CurrentDevice`) and display name

### Required Permissions
- Add to Info.plist: `NSMicrophoneUsageDescription` for input device access

---

## Performance Requirements
- Total latency under 10 ms (target 5–7 ms).
- **Audio callbacks run on real-time audio thread** - strict requirements:
  - No heap allocations (pre-allocate all buffers during initialization)
  - No locks except minimal circular buffer lock (use NSLock, not dispatch queues)
  - No Objective-C message sends
  - No Swift runtime operations (use simple C-like code)
  - No heavy system calls
- Convolution block size recommended: 128–512 samples.
- Must handle 44.1 kHz and 48 kHz sample rates.
- **Buffer sizes**:
  - Typical: 512 frames at 48kHz = ~10ms latency
  - Circular buffer: 65536 bytes minimum = ~1.5 seconds at 48kHz stereo
- **Clock drift handling**:
  - Input and output devices have independent clocks
  - Circular buffer absorbs short-term drift
  - Long-term drift may require sample rate conversion

---

## Compatibility Requirements
- macOS 12+
- Only Apple Silicon support
- Universal macOS binary
- Headphones required for correct output

---

## Preset System
- Each preset is a **single multi-channel WAV file**
- Preset file format:
  - One WAV file containing multiple channels (2+ channels recommended)
  - Channels 0 and 1 are used as Left and Right IR respectively
  - File naming convention: user-defined (e.g., "my-preset.wav")
- Preset metadata stored alongside files:
  - Preset name (derived from filename or user-defined)
  - Source/origin information (optional)
  - Original sample rate (from WAV file header)
  - Channel count (from WAV file header)
- Presets stored in: `~/Library/Application Support/mac-hrir-dsp/presets`
- UI must allow:
  - Adding a preset (select multi-channel WAV file)
  - Removing a preset
  - Choosing the active preset
  - Display preset information (name, channels, sample rate)

---

## Error Handling
- Must detect:
  - Invalid HRIR file
  - Missing device
  - Device sample rate mismatch
  - Unsupported channel configurations
  - Audio engine initialization failures
- **Must display detailed, debuggable error messages** that clearly explain what error occurred
- UI must show errors in a non-blocking manner.
- DSP engine must continue running if possible, falling back to bypass mode.

---

## Build & Packaging
- Xcode workspace with:
- SwiftUI App target
- C++ DSP static library
- Optional virtual device plugin target
- Support for codesigning and notarization
- Distributable as a DMG

---

## Testing Checklist

### Device Selection Testing
- [ ] Select different input device from system default
- [ ] Select different output device from system default
- [ ] Verify system defaults don't change (check System Settings → Sound)
- [ ] Test mono input device
- [ ] Test stereo input device
- [ ] Test multi-channel devices (if available)
- [ ] Test device switching while audio is active
- [ ] Test hot-plugging devices (connect/disconnect while running)

### Audio Quality Testing
- [ ] Verify audio quality (no distortion, dropouts, or glitches)
- [ ] Test with different sample rates (44.1kHz, 48kHz)
- [ ] Test with different buffer sizes
- [ ] Verify latency is under 10ms
- [ ] Test HRIR convolution on/off toggle
- [ ] Test preset switching during playback

### Stability Testing
- [ ] Test starting/stopping multiple times
- [ ] Test running for extended periods (1+ hours)
- [ ] Check for memory leaks (use Instruments)
- [ ] Test with no input signal
- [ ] Test with sustained high-level input
- [ ] Test device format changes during runtime

### Error Handling Testing
- [ ] Test with invalid HRIR file
- [ ] Test with missing HRIR preset
- [ ] Test disconnecting active device
- [ ] Test with unsupported sample rates
- [ ] Verify error messages are clear and debuggable

---

## Deliverables
- A working macOS application
- Ability to process all system audio with HRIR convolution
- Clean SwiftUI interface
- End-to-end latency under 10 ms
- Open-source repository ready for GitHub