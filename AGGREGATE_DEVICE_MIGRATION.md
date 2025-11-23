# Aggregate Device Architecture Migration Plan

## Overview

This document outlines the migration from the current dual-unit architecture (separate input/output AudioUnits with circular buffer) to a simplified single I/O unit architecture using macOS Aggregate Devices.

### Current Architecture
```
Input Device → Input AudioUnit → Input Callback → Circular Buffer (65KB)
                                                        ↓
                                                   Drift Compensator
                                                   (PID + Resampling)
                                                        ↓
Output Callback ← Output AudioUnit ← Output Device ← HRIR Convolution
```

### New Architecture
```
Aggregate Device (user-created) → Single I/O AudioUnit → Single Callback:
    1. Pull input (AudioUnitRender element 1)
    2. HRIR Convolution
    3. Write output (ioData)
```

### Key Benefits
- ✅ **Eliminates 2-hour drift crash** - macOS handles clock synchronization
- ✅ **~500-600 lines of code removed** - simpler codebase
- ✅ **Lower latency** - no buffering delay (65KB buffer eliminated)
- ✅ **Lower CPU overhead** - no drift compensation or adaptive resampling
- ✅ **Zero thread synchronization** - no NSLock, no circular buffer
- ✅ **Simpler debugging** - single code path, single callback

### Trade-offs
- ❌ **UX change** - users must manually create aggregate devices in Audio MIDI Setup
- ❌ **Less "plug and play"** - requires one-time setup per device combination
- ❌ **Aggregate limitations** - devices must be compatible, can't be used elsewhere

---

## Code Changes

### 1. Files to Delete Entirely

#### `CircularBuffer.swift`
- Entire ring buffer implementation
- Lock-based read/write synchronization
- ~200 lines removed

#### `DriftCompensator.swift` (if exists)
- PID controller for drift compensation
- Buffer fill level monitoring
- Resampling ratio calculation

### 2. AudioGraphManager.swift Changes

#### Properties to Remove (lines 49-73, 82-84)
```swift
// DELETE:
fileprivate var inputUnit: AudioUnit?
fileprivate var outputUnit: AudioUnit?
fileprivate let circularBuffer: CircularBuffer
fileprivate var isBuffering: Bool = true
fileprivate var underrunCount: Int = 0
fileprivate var fillLevelSamples: [Int] = []
fileprivate var minFillLevel: Int = 0
fileprivate var maxFillLevel: Int = 0
fileprivate var driftCompensator: DriftCompensator!
fileprivate var resampleOutputBuffer: UnsafeMutablePointer<Float>!
fileprivate var resampleControlBuffer: UnsafeMutablePointer<Float>!
fileprivate let maxResampleFrames: Int = 4200
fileprivate var inputAudioBufferListPtr: UnsafeMutableRawPointer?
fileprivate var inputAudioBuffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>?
```

#### Properties to Add
```swift
// NEW:
fileprivate var ioUnit: AudioUnit?  // Single unit in I/O mode
```

#### Published Properties to Change (lines 20-21)
```swift
// BEFORE:
@Published var inputDevice: AudioDevice?
@Published var outputDevice: AudioDevice?

// AFTER:
@Published var selectedDevice: AudioDevice?
```

#### BufferStats Struct (lines 24-43)
```swift
// SIMPLIFY or REMOVE - drift stats no longer needed
// Keep only if you want basic monitoring:
struct BufferStats {
    let isActive: Bool
    let sampleRate: Double
    let inputChannels: Int
    // Remove: capacity, bytesUsed, percentFull, underrunCount, etc.
}
```

#### init() Changes (lines 91-138)
```swift
// DELETE:
- CircularBuffer initialization
- DriftCompensator initialization
- Resampling buffer allocation (resampleOutputBuffer, resampleControlBuffer)
- InputAudioBufferList allocation (inputAudioBufferListPtr)
- InputAudioBuffers allocation (inputAudioBuffersPtr)

// KEEP:
- inputChannelBufferPtrs allocation (needed for HRIR processing)
- outputStereoLeftPtr/RightPtr allocation (needed for HRIR processing)
```

#### deinit() Changes (lines 140-168)
```swift
// DELETE deallocations for:
- inputAudioBufferListPtr
- inputAudioBuffersPtr
- resampleOutputBuffer
- resampleControlBuffer

// KEEP deallocations for:
- inputChannelBufferPtrs
- outputStereoLeftPtr/RightPtr
```

#### start() Method (lines 173-229)
```swift
// REPLACE entire method:
func start() {
    guard let device = selectedDevice else {
        errorMessage = "Please select an aggregate device"
        return
    }

    // Validate device still exists
    let allDevices = AudioDeviceManager.getAllDevices()
    guard allDevices.contains(where: { $0.id == device.id }) else {
        errorMessage = "Device '\(device.name)' is no longer available"
        return
    }

    stop()

    do {
        try setupIOUnit(device: device)  // Single setup call

        // Notify HRIR manager (same as before)
        if let hrirManager = hrirManager, let activePreset = hrirManager.activePreset {
            let inputLayout = InputLayout.detect(channelCount: Int(inputChannelCount))
            hrirManager.activatePreset(
                activePreset,
                targetSampleRate: currentSampleRate,
                inputLayout: inputLayout
            )
        }

        // Single start call
        var status = AudioOutputUnitStart(ioUnit!)
        guard status == noErr else {
            throw AudioError.startFailed(status, "Failed to start I/O unit")
        }

        DispatchQueue.main.async {
            self.isRunning = true
            self.errorMessage = nil
        }

    } catch {
        DispatchQueue.main.async {
            self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
            self.isRunning = false
        }
    }
}
```

#### stop() Method (lines 232-252)
```swift
// SIMPLIFY:
func stop() {
    if let io = ioUnit {
        AudioOutputUnitStop(io)
        AudioUnitUninitialize(io)
        AudioComponentInstanceDispose(io)
        ioUnit = nil
    }

    DispatchQueue.main.async {
        self.isRunning = false
    }
}
```

#### Device Selection Methods (lines 254-268)
```swift
// REPLACE both methods with single:
func selectDevice(_ device: AudioDevice) {
    selectedDevice = device
    if isRunning {
        start()
    }
}
```

#### getBufferStats() Method (lines 274-296)
```swift
// SIMPLIFY or REMOVE:
func getBufferStats() -> BufferStats {
    return BufferStats(
        isActive: isRunning,
        sampleRate: currentSampleRate,
        inputChannels: Int(inputChannelCount)
    )
}
```

#### resetDriftStats() Method (lines 299-304)
```swift
// DELETE - no longer needed
```

#### setupInputUnit() Method (lines 308-437)
```swift
// DELETE ENTIRELY
```

#### setupOutputUnit() Method (lines 439-537)
```swift
// DELETE ENTIRELY
```

#### NEW: setupIOUnit() Method
```swift
// ADD NEW METHOD (see detailed implementation below)
private func setupIOUnit(device: AudioDevice) throws {
    // Create HAL Output unit
    // Enable I/O on both input (element 1) and output (element 0)
    // Set aggregate device
    // Configure non-interleaved formats
    // Set render callback
    // Initialize
}
```

#### inputRenderCallback() (lines 542-666)
```swift
// DELETE ENTIRELY
```

#### outputRenderCallback() (lines 668-821)
```swift
// DELETE ENTIRELY
```

#### NEW: ioRenderCallback()
```swift
// ADD NEW CALLBACK (see detailed implementation below)
private func ioRenderCallback(...) -> OSStatus {
    // 1. Pull input via AudioUnitRender(element 1)
    // 2. Copy to processing buffers
    // 3. HRIR convolution (existing logic)
    // 4. Write to output (ioData)
}
```

---

## Detailed Implementation

### setupIOUnit() Implementation

```swift
private func setupIOUnit(device: AudioDevice) throws {
    var componentDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    guard let component = AudioComponentFindNext(nil, &componentDesc) else {
        throw AudioError.componentNotFound
    }

    var unit: AudioUnit?
    var status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let ioUnit = unit else {
        throw AudioError.instantiationFailed(status)
    }

    // Enable I/O on both input (element 1) and output (element 0)
    var enableIO: UInt32 = 1

    status = AudioUnitSetProperty(
        ioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,  // Input element
        &enableIO,
        UInt32(MemoryLayout<UInt32>.size)
    )
    guard status == noErr else {
        throw AudioError.propertySetFailed(status, "Failed to enable input")
    }

    status = AudioUnitSetProperty(
        ioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,  // Output element
        &enableIO,
        UInt32(MemoryLayout<UInt32>.size)
    )
    guard status == noErr else {
        throw AudioError.propertySetFailed(status, "Failed to enable output")
    }

    // Set the aggregate device (BEFORE format)
    var deviceID = device.id
    status = AudioUnitSetProperty(
        ioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw AudioError.deviceSetFailed(status)
    }

    // Get input format (element 1)
    var inputFormat = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = AudioUnitGetProperty(
        ioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,  // Output scope of input element
        1,
        &inputFormat,
        &size
    )
    guard status == noErr else {
        throw AudioError.formatGetFailed(status)
    }

    inputChannelCount = inputFormat.mChannelsPerFrame
    currentSampleRate = inputFormat.mSampleRate

    print("[AudioGraph] Aggregate device: \(device.name), Channels: \(inputChannelCount), Sample Rate: \(currentSampleRate)")

    // Set non-interleaved format on input side (element 1, output scope)
    var streamFormat = AudioStreamBasicDescription(
        mSampleRate: inputFormat.mSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: inputFormat.mChannelsPerFrame,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    status = AudioUnitSetProperty(
        ioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &streamFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    )
    guard status == noErr else {
        throw AudioError.formatSetFailed(status)
    }

    // Set stereo format on output side (element 0, input scope)
    streamFormat.mChannelsPerFrame = 2  // Stereo output
    outputChannelCount = 2

    status = AudioUnitSetProperty(
        ioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &streamFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    )
    guard status == noErr else {
        throw AudioError.formatSetFailed(status)
    }

    // Set render callback
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var callback = AURenderCallbackStruct(
        inputProc: ioRenderCallback,
        inputProcRefCon: selfPtr
    )

    status = AudioUnitSetProperty(
        ioUnit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    )
    guard status == noErr else {
        throw AudioError.callbackSetFailed(status)
    }

    status = AudioUnitInitialize(ioUnit)
    guard status == noErr else {
        throw AudioError.initializationFailed(status, "I/O unit")
    }

    self.ioUnit = ioUnit
}
```

### ioRenderCallback() Implementation

```swift
private func ioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let manager = Unmanaged<AudioGraphManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioUnit = manager.ioUnit else { return noErr }

    let frameCount = Int(inNumberFrames)
    let inputChannelCount = Int(manager.inputChannelCount)
    let bytesPerChannel = frameCount * MemoryLayout<Float>.size

    // Validate
    guard frameCount <= manager.maxFramesPerCallback,
          inputChannelCount <= manager.maxChannels else {
        return kAudioUnitErr_TooManyFramesToProcess
    }

    // STEP 1: Allocate temporary AudioBufferList for input
    let bufferListSize = MemoryLayout<AudioBufferList>.size +
                         max(0, inputChannelCount - 1) * MemoryLayout<AudioBuffer>.size

    let bufferListPointer = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }

    let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    audioBufferList.pointee.mNumberBuffers = UInt32(inputChannelCount)

    // Point buffers to our pre-allocated channel buffers
    guard let channelPtrs = manager.inputChannelBufferPtrs else { return noErr }

    withUnsafeMutablePointer(to: &audioBufferList.pointee.mBuffers) { buffersPtr in
        let bufferPtr = UnsafeMutableRawPointer(buffersPtr).assumingMemoryBound(to: AudioBuffer.self)

        for i in 0..<inputChannelCount {
            let buffer = bufferPtr.advanced(by: i)
            buffer.pointee.mNumberChannels = 1
            buffer.pointee.mDataByteSize = UInt32(bytesPerChannel)
            buffer.pointee.mData = UnsafeMutableRawPointer(channelPtrs[i])
        }
    }

    // STEP 2: Pull input from element 1
    let status = AudioUnitRender(
        ioUnit,
        ioActionFlags,
        inTimeStamp,
        1,  // Input element
        inNumberFrames,
        audioBufferList
    )

    guard status == noErr else { return status }

    // STEP 3: Process through HRIR or passthrough
    let shouldProcess = manager.hrirManager?.isConvolutionActive ?? false

    if shouldProcess {
        manager.hrirManager?.processAudio(
            inputPtrs: channelPtrs,
            inputCount: inputChannelCount,
            leftOutput: manager.outputStereoLeftPtr,
            rightOutput: manager.outputStereoRightPtr,
            frameCount: frameCount
        )
    } else {
        // PASSTHROUGH: Mix down to stereo
        memset(manager.outputStereoLeftPtr, 0, bytesPerChannel)
        memset(manager.outputStereoRightPtr, 0, bytesPerChannel)

        if inputChannelCount > 0 {
            memcpy(manager.outputStereoLeftPtr, channelPtrs[0], bytesPerChannel)

            if inputChannelCount >= 2 {
                memcpy(manager.outputStereoRightPtr, channelPtrs[1], bytesPerChannel)
            } else {
                memcpy(manager.outputStereoRightPtr, channelPtrs[0], bytesPerChannel)
            }
        }
    }

    // STEP 4: Write output to ioData
    guard let bufferList = ioData else { return noErr }

    withUnsafeMutablePointer(to: &bufferList.pointee.mBuffers) { buffersPtr in
        let bufferPtr = UnsafeMutableRawPointer(buffersPtr).assumingMemoryBound(to: AudioBuffer.self)

        for i in 0..<min(Int(bufferList.pointee.mNumberBuffers), 2) {
            let buffer = bufferPtr.advanced(by: i)
            if let data = buffer.pointee.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                let sourcePtr = (i == 0) ? manager.outputStereoLeftPtr : manager.outputStereoRightPtr
                memcpy(samples, sourcePtr, bytesPerChannel)
            }
        }
    }

    return noErr
}
```

---

## UI Changes

### Device Selection Interface

#### Before (Two Pickers)
```swift
Picker("Input Device", selection: $audioGraph.inputDevice) { ... }
Picker("Output Device", selection: $audioGraph.outputDevice) { ... }
```

#### After (Single Picker)
```swift
VStack(alignment: .leading) {
    Text("Aggregate Device")
        .font(.headline)

    Text("Create an aggregate device in Audio MIDI Setup combining your input and output devices")
        .font(.caption)
        .foregroundColor(.secondary)

    Picker("Device", selection: $audioGraph.selectedDevice) {
        ForEach(AudioDeviceManager.getAllDevices()) { device in
            Text(device.name).tag(device as AudioDevice?)
        }
    }

    // Optional: Validation indicator
    if let device = audioGraph.selectedDevice {
        if validateAggregateDevice(device) {
            Label("Valid aggregate device", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        } else {
            Label("Warning: This may not be an aggregate device", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
        }
    }
}
```

#### Optional Helper Function
```swift
// Validate that device has both input and output streams
func validateAggregateDevice(_ device: AudioDevice) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &dataSize)
    let hasInput = dataSize > 0

    address.mScope = kAudioDevicePropertyScopeOutput
    AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &dataSize)
    let hasOutput = dataSize > 0

    return hasInput && hasOutput
}
```

---

## Migration Steps

### Phase 1: Preparation
1. ✅ Create this migration document
2. ✅ Review and approve architecture changes
3. Create git branch: `feature/aggregate-device-architecture`
4. Run full test suite and document current behavior
5. Create user guide for aggregate device setup

### Phase 2: Code Removal
1. Comment out (don't delete yet) drift compensation code in `AudioGraphManager.swift`
   - Lines 599-662 (resampling in input callback)
   - Lines 709-753 (buffering and drift tracking in output callback)
2. Run tests - verify nothing breaks (drift will still occur but app should function)
3. Delete `CircularBuffer.swift`
4. Delete `DriftCompensator.swift` (if exists)
5. Commit: "Remove drift compensation infrastructure"

### Phase 3: AudioUnit Consolidation
1. Add `ioUnit` property
2. Implement `setupIOUnit()` method
3. Implement `ioRenderCallback()` function
4. Update `start()` method to use new setup
5. Update `stop()` method
6. Test with a manually created aggregate device
7. Commit: "Implement I/O unit with aggregate device support"

### Phase 4: Property Cleanup
1. Remove old properties (`inputUnit`, `outputUnit`, buffers, stats)
2. Update `init()` and `deinit()`
3. Change published properties to single `selectedDevice`
4. Remove `getBufferStats()` or simplify significantly
5. Commit: "Clean up deprecated properties and buffers"

### Phase 5: UI Updates
1. Update device selection UI to single picker
2. Add aggregate device helper text
3. Optional: Add validation indicator
4. Update any stats displays
5. Commit: "Update UI for aggregate device selection"

### Phase 6: Documentation
1. Update `CLAUDE.md` with new architecture
2. Update `PASSTHROUGH_SPEC.md` (if relevant)
3. Create `AGGREGATE_DEVICE_SETUP.md` user guide
4. Update README.md
5. Commit: "Update documentation for aggregate device architecture"

### Phase 7: Testing
1. Test with various aggregate device configurations:
   - Built-in mic + built-in speakers
   - USB interface + built-in speakers
   - Built-in mic + USB interface
2. Test multi-channel scenarios (2.0, 5.1, 7.1)
3. Long-duration testing (4+ hours)
4. Verify no audio dropouts or glitches
5. Performance profiling (CPU, memory)

### Phase 8: Release
1. Merge to main branch
2. Tag release: `v2.0.0-aggregate-architecture`
3. Update release notes highlighting aggregate device requirement

---

## Testing Strategy

### Unit Tests (if applicable)
- Test `setupIOUnit()` with mock devices
- Test callback with various buffer sizes
- Test HRIR processing path (unchanged)

### Manual Testing Checklist

#### Basic Functionality
- [ ] App launches without errors
- [ ] Aggregate device appears in device list
- [ ] Can select aggregate device
- [ ] Audio starts when device selected
- [ ] Audio stops cleanly
- [ ] Can switch between devices
- [ ] Can enable/disable HRIR processing

#### Audio Quality
- [ ] No clicks or pops during playback
- [ ] No audible artifacts
- [ ] Stereo imaging correct
- [ ] Multi-channel mapping correct (5.1, 7.1)
- [ ] HRIR convolution sounds correct
- [ ] Passthrough mode works

#### Stability
- [ ] No crashes after 4+ hours
- [ ] No memory leaks (check Activity Monitor)
- [ ] CPU usage stays low (<10%)
- [ ] No drift-related issues
- [ ] Device changes handled gracefully
- [ ] Device disconnection doesn't crash app

#### Edge Cases
- [ ] Aggregate device with mismatched sample rates
- [ ] Aggregate device disconnect during playback
- [ ] Switching aggregates while playing
- [ ] Very large buffer sizes (4096 frames)
- [ ] Very small buffer sizes (64 frames)

---

## Risks and Mitigation

### Risk 1: AudioUnitRender() in I/O callback may introduce latency
**Mitigation**: This is standard CoreAudio practice. The aggregate device handles synchronization, so no additional latency beyond hardware buffers.

### Risk 2: Users unfamiliar with Audio MIDI Setup
**Mitigation**:
- Provide clear step-by-step guide with screenshots
- Link to Apple's documentation
- Consider adding in-app tutorial or link to video guide

### Risk 3: Aggregate device creation fails for some hardware
**Mitigation**:
- Test with wide variety of hardware
- Document known incompatibilities
- Provide troubleshooting guide

### Risk 4: Breaking changes for existing users
**Mitigation**:
- Major version bump (v2.0.0)
- Clear migration guide in release notes
- Consider keeping v1.x available for users who can't migrate

### Risk 5: Non-interleaved format issues with aggregate devices
**Mitigation**:
- Explicitly set format after device assignment
- Validate format before initialization
- Add detailed error messages if format negotiation fails

---

## Rollback Plan

If critical issues discovered post-migration:

1. **Immediate**: Revert merge commit, restore previous release
2. **Short-term**: Create hotfix branch from last stable tag
3. **Long-term**: Address issues in aggregate architecture before re-attempting migration

Keep `v1.x` branch maintained until `v2.0` proven stable in production for 2+ weeks.

---

## Success Metrics

Migration considered successful when:
- ✅ Zero drift-related crashes after 8+ hours continuous use
- ✅ CPU usage reduced by >5% compared to v1.x
- ✅ Code base reduced by 500+ lines
- ✅ No new audio quality regressions
- ✅ User feedback indicates aggregate setup is manageable
- ✅ All automated tests passing

---

## Future Enhancements (Post-Migration)

Once aggregate architecture is stable:

1. **Programmatic aggregate creation** (if UX feedback negative)
   - Use `AudioHardwareCreateAggregateDevice()` API
   - Auto-create/destroy aggregates on demand
   - Adds complexity but improves UX

2. **Multi-output support**
   - Use aggregate device to output to multiple devices simultaneously
   - Useful for monitoring/recording scenarios

3. **Sample rate mismatch handling**
   - Detect when aggregate has sample rate conversion enabled
   - Warn user about potential quality loss

---

## Questions to Resolve Before Implementation

- [ ] Do we want to support legacy dual-device mode in parallel? (NO - clean break is better)
- [ ] Should we add aggregate device validation/detection? (OPTIONAL - nice to have)
- [ ] What's the minimum macOS version that supports our use case reliably? (Already set to 12.0+)
- [ ] Do we need migration path for user settings? (NO - single device picker is new UI)

---

## Approval Checklist

- [ ] Architecture reviewed and approved
- [ ] UI/UX changes reviewed
- [ ] Testing strategy approved
- [ ] Documentation plan approved
- [ ] Timeline agreed upon
- [ ] Risk mitigation acceptable

---

**Last Updated**: 2025-11-23
**Status**: Draft - Pending Approval
**Author**: Claude Code
**Reviewers**: [To be filled]
