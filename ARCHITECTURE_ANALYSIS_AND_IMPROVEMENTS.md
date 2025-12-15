# MacHRIR Architecture Analysis & Improvement Opportunities

**Analysis Date**: 2025-11-23
**Branch**: system_aggregate_device
**Architecture**: Multi-Output Aggregate Device with Channel Routing

---

## Executive Summary

The current implementation is **well-architected** and successfully implements the multi-output aggregate device pattern. The code shows evidence of careful optimization (zero-allocation audio callbacks, pre-allocated buffers, shared FFT setups). However, there are **significant opportunities for improvement** in the following areas:

### High-Priority Improvements

1. **Memory Efficiency**: Redundant device info storage, inefficient UID queries
2. **Settings Performance**: Excessive save operations causing I/O overhead
3. **Thread Safety**: Potential race conditions in HRIR manager state updates
4. **Audio Callback Optimization**: Unnecessary bounds checks and pointer operations

### Medium-Priority Improvements

5. **Error Handling**: Silent failures, incomplete validation
6. **Code Duplication**: Repeated CoreAudio property queries
7. **User Experience**: Missing edge case handling, unclear error messages

### Architecture Strengths

✅ Clean separation of concerns
✅ Zero-allocation audio callbacks (mostly)
✅ Proper memory pre-allocation
✅ Good use of Combine for state management

---

## 1. Performance Optimizations

### 1.1 Settings Manager: Excessive Save Operations ⚠️ HIGH IMPACT

**Current Issue**:

```swift
// SettingsManager.swift
func setOutputDevice(_ deviceID: AudioDeviceID) {
    var settings = loadSettings()  // ❌ Full JSON decode
    settings.selectedOutputDeviceID = deviceID
    saveSettings(settings)          // ❌ Full JSON encode + disk write
}
```

**Problem**: Every output device switch triggers:

1. Load entire settings JSON from UserDefaults
2. Decode JSON
3. Modify one field
4. Encode entire JSON
5. Write to disk
6. Synchronize UserDefaults

**Impact**:

- When user rapidly switches output devices, each switch causes full serialize/deserialize cycle
- `defaults.synchronize()` is **deprecated** and unnecessary (UserDefaults auto-syncs)
- MenuBarManager debounces saves (300ms), but SettingsManager helpers bypass this

**Recommendation**:

```swift
// Option 1: Cache settings in memory
class SettingsManager {
    private var cachedSettings: AppSettings?
    private var saveWorkItem: DispatchWorkItem?

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        ensureCacheLoaded()
        cachedSettings?.selectedOutputDeviceID = deviceID
        debounceSave()
    }

    private func debounceSave() {
        saveWorkItem?.cancel()
        saveWorkItem = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: saveWorkItem!)
    }
}

// Option 2: Remove helper methods entirely, force callers to use performSave()
// MenuBarManager already has debouncing logic - don't bypass it
```

**Estimated Impact**: Reduce I/O overhead by 90% during rapid device switching

---

### 1.2 AggregateDeviceInspector: Redundant Device Lookups ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// AggregateDeviceInspector.swift:196-205
private func findDeviceByUID(_ uid: String) -> AudioDevice? {
    let allDevices = AudioDeviceManager.getAllDevices()  // ❌ Enumerates ALL devices

    for device in allDevices {
        if let deviceUID = getDeviceUID(deviceID: device.id), deviceUID == uid {
            return device
        }
    }
    return nil
}
```

**Problem**:

- `getAllDevices()` queries CoreAudio for every device on system
- For each device, queries name, channels, sample rate, transport type
- This happens for EVERY sub-device in the aggregate
- If aggregate has 4 sub-devices, queries ALL system devices 4 times

**Recommendation**:

```swift
// Cache device list during getSubDevices() call
func getSubDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
    let uids = try getSubDeviceUIDs(aggregate: aggregate)

    // Build device lookup table ONCE
    let allDevices = AudioDeviceManager.getAllDevices()
    let devicesByUID = Dictionary(uniqueKeysWithValues:
        allDevices.compactMap { device -> (String, AudioDevice)? in
            guard let uid = getDeviceUID(deviceID: device.id) else { return nil }
            return (uid, device)
        }
    )

    return try buildChannelMap(subDeviceUIDs: uids, deviceLookup: devicesByUID)
}
```

**Estimated Impact**: Reduce device enumeration from O(N×M) to O(N+M) where N=system devices, M=sub-devices

---

### 1.3 AudioGraphManager: Unnecessary Bounds Checks in Hot Path ⚠️ LOW IMPACT

**Current Issue**:

```swift
// AudioGraphManager.swift:429-431 (render callback)
if frameCount > manager.maxFramesPerCallback || inputChannelCount > manager.maxChannels {
     return kAudioUnitErr_TooManyFramesToProcess
}
```

**Problem**:

- This check happens on EVERY audio callback (~21000 times per second @ 512 samples, 48kHz)
- CoreAudio should never violate these constraints (we set the format)
- If it does, the audio stream is already broken - checking won't help

**Recommendation**:

```swift
// Move to debug-only assertion
#if DEBUG
if frameCount > manager.maxFramesPerCallback || inputChannelCount > manager.maxChannels {
    assertionFailure("CoreAudio contract violation")
    return kAudioUnitErr_TooManyFramesToProcess
}
#endif
```

**Estimated Impact**: Minimal (<0.1% CPU), but adheres to zero-overhead principle

---

### 1.4 ConvolutionEngine: Struct Initialization in Hot Loop ⚠️ ALREADY OPTIMIZED ✅

**Current State**:

```swift
// ConvolutionEngine.swift:302-306
var fdlSplit = DSPSplitComplex(realp: fdlRealPtrLocal[0], imagp: fdlImagPtrLocal[0])
var hrirSplit = DSPSplitComplex(realp: hrirRealPtrLocal[0], imagp: hrirImagPtrLocal[0])
// ...reused in loop by updating pointers
```

**Analysis**: This is **correctly optimized**. Structs are allocated on stack once, then pointers are updated. No heap allocation. ✅

---

### 1.5 HRIRManager: Lock-Free State Access ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// HRIRManager.swift:72-73
private var rendererState: RendererState?

// Access in audio callback (AudioGraphManager.swift:478-479)
manager.hrirManager?.processAudio(...)
```

**Problem**:

- `rendererState` is a class reference that can be swapped on background thread
- Swift class references are not atomic
- Potential race: audio thread reads `rendererState` while background thread updates it
- **Partial mitigation**: `RendererState` is immutable container (good design!)
- **Remaining issue**: Reference swap itself is not atomic

**Recommendation**:

```swift
import Foundation

class HRIRManager {
    // Use OSAtomic or atomic property wrapper
    private var _rendererState: RendererState?
    private let stateLock = NSLock()  // Lightweight for single-pointer swap

    private var rendererState: RendererState? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _rendererState
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _rendererState = newValue
        }
    }
}
```

**Alternative** (macOS 13+):

```swift
private var rendererState: RendererState? {
    @storageRestrictions(initializes: _rendererState)
    init(initialValue) { ... }
    get { atomicLoad() }
    set { atomicStore(newValue) }
}
```

**Estimated Impact**: Eliminate rare but catastrophic race condition

---

## 2. Architecture & Design Improvements

### 2.1 AudioDevice: Redundant Property Storage ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// AudioDevice.swift:13-20
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let sampleRate: Double
    let channelCount: UInt32
    let isAggregateDevice: Bool
}
```

**Problem**:

- All properties except `id` are **redundant** - they can be queried from CoreAudio
- Storing them means they can become stale if device configuration changes
- `AudioDeviceManager` already queries these properties dynamically

**Specific Issues**:

1. **Stale channel counts**: If user changes aggregate device configuration, cached `channelCount` is wrong
2. **Stale sample rates**: If user changes device sample rate, cached value is wrong
3. **Memory overhead**: Each device stores 40+ bytes of redundant data

**Recommendation**:

```swift
// Minimal struct - only store immutable ID
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID

    // Computed properties query CoreAudio dynamically
    var name: String { AudioDeviceManager.getDeviceName(deviceID: id) ?? "Unknown" }
    var hasInput: Bool { AudioDeviceManager.getChannelCount(deviceID: id, scope: .input) > 0 }
    var hasOutput: Bool { AudioDeviceManager.getChannelCount(deviceID: id, scope: .output) > 0 }
    var sampleRate: Double { AudioDeviceManager.getSampleRate(deviceID: id) }
    var channelCount: UInt32 {
        hasInput ? AudioDeviceManager.getChannelCount(deviceID: id, scope: .input)
                 : AudioDeviceManager.getChannelCount(deviceID: id, scope: .output)
    }
    var isAggregateDevice: Bool { AudioDeviceManager.isAggregateDevice(deviceID: id) }
}
```

**Tradeoff**: More CoreAudio queries vs. always-correct device info

**Alternative** (if performance is concern):

```swift
// Cache with invalidation
extension AudioDeviceManager {
    private var deviceInfoCache: [AudioDeviceID: (info: AudioDevice, timestamp: Date)] = [:]
    private let cacheValidityDuration: TimeInterval = 1.0  // 1 second

    func getDeviceInfo(deviceID: AudioDeviceID, allowCached: Bool = true) -> AudioDevice? {
        if allowCached,
           let cached = deviceInfoCache[deviceID],
           Date().timeIntervalSince(cached.timestamp) < cacheValidityDuration {
            return cached.info
        }

        // Query and cache
        let info = queryDeviceInfo(deviceID: deviceID)
        deviceInfoCache[deviceID] = (info, Date())
        return info
    }
}
```

---

### 2.2 SubDeviceInfo: Missing Input Channel Information ⚠️ LOW IMPACT

**Current Issue**:

```swift
// AggregateDeviceInspector.swift:9-25
struct SubDeviceInfo {
    let device: AudioDevice
    let uid: String
    let name: String
    let startChannel: Int
    let channelCount: Int
    let direction: Direction  // input or output
}
```

**Problem**:

- For aggregates with BOTH input and output on same physical device, this creates TWO `SubDeviceInfo` instances
- Example: USB audio interface with 8 inputs + 8 outputs → 2 entries, same device
- UI shows device twice in potentially confusing way

**Current Behavior**:

```
Output Device:
├── USB Interface (Ch 0-7)    ← Input instance
├── USB Interface (Ch 0-7)    ← Output instance
└── Headphones (Ch 8-9)
```

**Recommendation**:

```swift
struct SubDeviceInfo {
    let device: AudioDevice
    let uid: String
    let name: String
    let inputChannelRange: Range<Int>?   // nil if no input
    let outputChannelRange: Range<Int>?  // nil if no output

    var isInputOnly: Bool { inputChannelRange != nil && outputChannelRange == nil }
    var isOutputOnly: Bool { outputChannelRange != nil && inputChannelRange == nil }
    var isBidirectional: Bool { inputChannelRange != nil && outputChannelRange != nil }
}
```

**Benefit**: One entry per physical device, clearer semantics

---

### 2.3 MenuBarManager: Missing Aggregate Validation ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// MenuBarManager.swift:277-291
do {
    availableOutputs = try inspector.getOutputDevices(aggregate: device)

    if let firstOutput = availableOutputs.first {
        selectedOutputDevice = firstOutput
        // ...
    }
} catch {
    print("Failed to configure aggregate device: \(error)")  // ❌ Only printed to console
}
```

**Problem**:

- If aggregate has no output devices, error is only logged
- User sees "No output devices in aggregate" but no guidance on what to do
- No validation that aggregate has BOTH input and output

**Recommendation**:

```swift
// Add validation helper
private func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?) {
    do {
        let inputs = try inspector.getInputDevices(aggregate: device)
        let outputs = try inspector.getOutputDevices(aggregate: device)

        if inputs.isEmpty {
            return (false, "Aggregate device '\(device.name)' has no input devices.\n\nPlease add an input device (e.g., BlackHole) in Audio MIDI Setup.")
        }

        if outputs.isEmpty {
            return (false, "Aggregate device '\(device.name)' has no output devices.\n\nPlease add output devices (e.g., Headphones, Speakers) in Audio MIDI Setup.")
        }

        // Check for at least stereo output capability
        let hasstereoOutput = outputs.contains { $0.channelCount >= 2 }
        if !hasstereoOutput {
            return (false, "Aggregate device '\(device.name)' has no stereo output.\n\nAt least one output device must have 2+ channels.")
        }

        return (true, nil)
    } catch {
        return (false, "Could not inspect aggregate device: \(error.localizedDescription)")
    }
}

@objc private func selectAggregateDevice(_ sender: NSMenuItem) {
    guard let device = sender.representedObject as? AudioDevice else { return }

    // Validate first
    let validation = validateAggregateDevice(device)
    if !validation.valid {
        showAlert(title: "Invalid Aggregate Device", message: validation.reason!)
        return
    }

    // ...rest of selection logic
}
```

---

## 3. Code Quality & Maintainability

### 3.1 Duplicated CoreAudio Property Queries ⚠️ LOW IMPACT

**Current Issue**:
Multiple places duplicate the same CoreAudio property query pattern:

- `AudioDeviceManager.getDeviceName()`
- `AudioDeviceManager.getChannelCount()`
- `AggregateDeviceInspector.getDeviceUID()`
- `AggregateDeviceInspector.getDeviceChannelCount()`

**Example**:

```swift
// AggregateDeviceInspector.swift:207-230
private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(...)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(...)
    // ...
}

// AudioDevice.swift:399-436
private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(...)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(...) == noErr else { return nil }
    // ...similar pattern
}
```

**Recommendation**:

```swift
// Create shared CoreAudio query utilities
enum CoreAudioQuery {
    static func getProperty<T>(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var value: T?
        var size = UInt32(MemoryLayout<T>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &value
        )

        return status == noErr ? value : nil
    }

    static func getCFStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        // ...specialized for CFString
    }
}

// Usage:
let uid = CoreAudioQuery.getCFStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
let sampleRate: Double? = CoreAudioQuery.getProperty(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate)
```

---

### 3.2 Error Types: Missing Localized Descriptions ⚠️ LOW IMPACT

**Current Issue**:

```swift
// AggregateDeviceInspector.swift:284-289
enum AggregateInspectorError: Error {
    case notAnAggregate
    case noSubDevices
    case deviceNotFound(uid: String)
    case propertyQueryFailed(OSStatus)
}
// ❌ Does not conform to LocalizedError
```

**Recommendation**:

```swift
enum AggregateInspectorError: LocalizedError {
    case notAnAggregate
    case noSubDevices
    case deviceNotFound(uid: String)
    case propertyQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notAnAggregate:
            return "Selected device is not an aggregate device"
        case .noSubDevices:
            return "Aggregate device contains no sub-devices"
        case .deviceNotFound(let uid):
            return "Sub-device '\(uid)' not found on system"
        case .propertyQueryFailed(let status):
            return "CoreAudio property query failed (error \(status))"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAnAggregate:
            return "Please select an aggregate device created in Audio MIDI Setup."
        case .noSubDevices:
            return "Please add devices to this aggregate in Audio MIDI Setup."
        case .deviceNotFound:
            return "The aggregate device references a device that is not connected. Please check Audio MIDI Setup."
        default:
            return nil
        }
    }
}
```

---

### 3.3 Magic Numbers ⚠️ LOW IMPACT

**Current Issue**:

```swift
// AudioGraphManager.swift:487-488
memset(manager.outputStereoLeftPtr, 0, frameCount * 4)
memset(manager.outputStereoRightPtr, 0, frameCount * 4)
// ❌ Magic number '4' = MemoryLayout<Float>.size
```

**Recommendation**:

```swift
let byteSize = frameCount * MemoryLayout<Float>.size
memset(manager.outputStereoLeftPtr, 0, byteSize)
memset(manager.outputStereoRightPtr, 0, byteSize)
```

---

## 4. User Experience Enhancements

### 4.1 Output Device Hot-Swap: No Audio Confirmation ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// MenuBarManager.swift:305-316
@objc private func selectOutputDevice(_ sender: NSMenuItem) {
    guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else { return }

    selectedOutputDevice = output
    let channelRange = output.startChannel..<(output.startChannel + 2)
    audioManager.setOutputChannels(channelRange)

    updateMenu()
    saveSettings()
}
```

**Problem**:

- User switches output device but gets no confirmation
- If channel range is invalid (e.g., mono output device), audio silently fails
- No visual/audio feedback that switch succeeded

**Recommendation**:

```swift
@objc private func selectOutputDevice(_ sender: NSMenuItem) {
    guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else { return }

    // Validate stereo capability
    guard output.channelCount >= 2 else {
        showAlert(
            title: "Invalid Output",
            message: "'\(output.name)' only has \(output.channelCount) channel(s). MacHRIR requires stereo (2+ channels) for output."
        )
        return
    }

    selectedOutputDevice = output
    let channelRange = output.startChannel..<(output.startChannel + 2)
    audioManager.setOutputChannels(channelRange)

    // Optional: Brief audio confirmation (beep or test tone)
    if audioManager.isRunning {
        playOutputConfirmationTone()  // 100ms sine wave to confirm routing
    }

    updateMenu()
    saveSettings()
}
```

---

### 4.2 Missing Device Disconnect Detection ⚠️ HIGH IMPACT

**Current Issue**:

- If user selects output device, then physically disconnects that device, app continues trying to output to non-existent channels
- No error message, audio just stops working

**Recommendation**:

```swift
// Add device alive check
extension AudioDevice {
    var isAlive: Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,  // Any property will do
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        return AudioObjectHasProperty(id, &propertyAddress)
    }
}

// In MenuBarManager, listen for device changes
private func setupDeviceDisconnectionMonitoring() {
    deviceManager.$aggregateDevices
        .sink { [weak self] devices in
            guard let self = self,
                  let aggregate = self.audioManager.aggregateDevice,
                  !devices.contains(where: { $0.id == aggregate.id }) else {
                return
            }

            // Aggregate device disconnected!
            self.audioManager.stop()
            self.audioManager.aggregateDevice = nil
            self.selectedOutputDevice = nil

            self.showAlert(
                title: "Device Disconnected",
                message: "Aggregate device '\(aggregate.name)' is no longer available. Please select a new device."
            )
        }
        .store(in: &cancellables)
}
```

---

### 4.3 First Launch: No Preset Guidance ⚠️ LOW IMPACT

**Current Issue**:

- User launches app for first time, sees empty preset list, no guidance

**Recommendation**:

```swift
// In MenuBarManager.buildMenu()
if hrirManager.presets.isEmpty {
    let emptyItem = NSMenuItem(title: "No HRIR presets found", action: nil, keyEquivalent: "")
    emptyItem.isEnabled = false
    presetsMenu.addItem(emptyItem)

    let helpItem = NSMenuItem(title: "Download HRIRs...", action: #selector(showHRIRDownloadHelp), keyEquivalent: "")
    helpItem.target = self
    presetsMenu.addItem(helpItem)
}

@objc private func showHRIRDownloadHelp() {
    let alert = NSAlert()
    alert.messageText = "Download HRIR Files"
    alert.informativeText = """
    To use MacHRIR, you need HRIR (Head-Related Impulse Response) files.

    Popular sources:
    • HeSuVi HRIR Pack: github.com/jaakkopasanen/AutoEq
    • Room EQ Wizard: reweq.com
    • Custom HRIRs: Record your own!

    Place .wav files in:
    ~/Library/Application Support/MacHRIR/presets/

    The folder will open when you click OK.
    """
    alert.addButton(withTitle: "OK")
    alert.runModal()

    hrirManager.openPresetsDirectory()
}
```

---

## 5. Memory Management

### 5.1 AudioGraphManager: Potential Memory Leak on Error ⚠️ LOW IMPACT

**Current Issue**:

```swift
// AudioGraphManager.swift:216-272
private func setupAudioUnit(device: AudioDevice, outputChannelRange: Range<Int>?) throws {
    var unit: AudioUnit?
    var status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let audioUnit = unit else {
        throw AudioError.instantiationFailed(status)
    }

    // ... many property set operations that can throw ...

    self.audioUnit = audioUnit  // ❌ Only set if ALL operations succeed
}
```

**Problem**:

- If any `throw` happens after `AudioComponentInstanceNew` but before `self.audioUnit = audioUnit`, the `AudioUnit` leaks
- Not a critical leak (system resources cleaned up on process exit), but sloppy

**Recommendation**:

```swift
private func setupAudioUnit(device: AudioDevice, outputChannelRange: Range<Int>?) throws {
    var unit: AudioUnit?
    var status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let audioUnit = unit else {
        throw AudioError.instantiationFailed(status)
    }

    // Ensure cleanup on error
    defer {
        if self.audioUnit == nil {
            // Setup failed, clean up temporary unit
            AudioComponentInstanceDispose(audioUnit)
        }
    }

    // ... property set operations ...

    // If we reach here, success - assign to property
    self.audioUnit = audioUnit
}
```

---

### 5.2 ConvolutionEngine: No Reset on Preset Change ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// HRIRManager.swift:225-227
let newState = RendererState(renderers: newRenderers)
self.rendererState = newState
// ❌ Old renderers deallocated, but their ConvolutionEngines retain state
```

**Problem**:

- When switching presets, old `ConvolutionEngine` instances are deallocated
- Their `fdlIndex` and `inputOverlapBuffer` retain previous audio
- **Actually not a problem** because new instances are created, but...
- If we ever add preset crossfade, this will cause artifacts

**Recommendation**: Document behavior or add explicit reset if needed

```swift
// Add method to HRIRManager if crossfade is added
func resetConvolutionState() {
    guard let state = rendererState else { return }
    for renderer in state.renderers {
        renderer.convolverLeftEar.reset()
        renderer.convolverRightEar.reset()
    }
}
```

---

## 6. Edge Cases & Bug Fixes

### 6.1 AudioGraphManager: Channel Range Validation ⚠️ HIGH IMPACT

**Current Issue**:

```swift
// AudioGraphManager.swift:520-534 (render callback)
if let channelRange = manager.selectedOutputChannelRange {
    let leftChannel = channelRange.lowerBound
    let rightChannel = leftChannel + 1

    if rightChannel < outputChannelCount {  // ✅ Good check
        // ... write to channels
    }
}
// ❌ If check fails, audio is silently dropped (all channels were zeroed)
```

**Problem**:

- If user manually edits aggregate device and removes output device, `selectedOutputChannelRange` becomes invalid
- Audio silently stops, no error message

**Recommendation**:

```swift
// In setOutputChannels()
func setOutputChannels(_ range: Range<Int>) {
    guard range.upperBound <= Int(outputChannelCount) else {
        DispatchQueue.main.async {
            self.errorMessage = "Output channel range \(range) exceeds device channel count (\(self.outputChannelCount))"
        }
        return
    }
    selectedOutputChannelRange = range
}

// In render callback, add DEBUG assertion
#if DEBUG
if let channelRange = manager.selectedOutputChannelRange {
    assert(channelRange.upperBound <= outputChannelCount, "Channel range validation failed!")
}
#endif
```

---

### 6.2 HRIRManager: Duplicate Preset Detection ⚠️ LOW IMPACT

**Current Issue**:

```swift
// HRIRManager.swift:369-389 (loadAndSyncPresets)
for fileURL in wavFiles {
    if let existing = knownPresets.first(where: { $0.fileURL.lastPathComponent == fileURL.lastPathComponent }) {
        // Keep existing
    } else {
        // New file!
        if let newPreset = try? createPreset(from: fileURL) {
            updatedPresets.append(newPreset)
        }
    }
}
```

**Problem**:

- If user renames HRIR file, it's treated as new preset (gets new UUID)
- Old preset with old filename stays in `presets.json`, but file is gone
- Result: Duplicate entries for same HRIR (one with old UUID pointing to non-existent file)

**Recommendation**:

```swift
// Clean up orphaned presets
let existingFilenames = Set(wavFiles.map { $0.lastPathComponent })
let orphanedPresets = knownPresets.filter { preset in
    !existingFilenames.contains(preset.fileURL.lastPathComponent)
}

if !orphanedPresets.isEmpty {
    print("[HRIRManager] Removing \(orphanedPresets.count) orphaned presets")
    hasChanges = true
}
```

---

### 6.3 AggregateDeviceInspector: Silent Device Lookup Failure ⚠️ MEDIUM IMPACT

**Current Issue**:

```swift
// AggregateDeviceInspector.swift:152-158
guard let device = findDeviceByUID(uid) else {
    print("Warning: Could not find device with UID \(uid)")
    continue  // ❌ Silently skip sub-device
}
```

**Problem**:

- If aggregate references disconnected device, it's silently skipped
- User sees fewer outputs than expected, no explanation why
- Example: Aggregate has "Headphones + USB DAC", USB DAC unplugged → only Headphones shown

**Recommendation**:

```swift
guard let device = findDeviceByUID(uid) else {
    throw AggregateInspectorError.deviceNotFound(uid: uid)
}
// Let caller decide how to handle missing sub-devices
```

---

## 7. Potential Future Enhancements

### 7.1 Latency Monitoring ⚠️ NICE TO HAVE

Add real-time latency display to menu:

```swift
// In AudioGraphManager, track timestamp delta
private var lastInputTimestamp: UInt64 = 0
private var currentLatencyMs: Double = 0

// In render callback:
let currentTime = inTimeStamp.pointee.mHostTime
if lastInputTimestamp > 0 {
    let deltaNanos = currentTime - lastInputTimestamp
    currentLatencyMs = Double(deltaNanos) / 1_000_000.0
}
lastInputTimestamp = currentTime
```

### 7.2 CPU Usage Monitoring ⚠️ NICE TO HAVE

Track callback CPU usage for performance debugging:

```swift
#if DEBUG
private var callbackDurationSum: UInt64 = 0
private var callbackCount: UInt64 = 0

func renderCallback(...) -> OSStatus {
    let start = mach_absolute_time()
    defer {
        let end = mach_absolute_time()
        callbackDurationSum += (end - start)
        callbackCount += 1

        if callbackCount % 1000 == 0 {
            let avgMicros = callbackDurationSum / callbackCount / 1000
            print("[AudioGraph] Avg callback time: \(avgMicros)µs")
        }
    }

    // ...existing code
}
#endif
```

### 7.3 Preset Metadata ⚠️ NICE TO HAVE

Add metadata to presets (author, speaker layout, etc.):

```swift
struct HRIRPresetMetadata: Codable {
    var description: String?
    var author: String?
    var speakerLayout: String?  // "7.1", "5.1.2", etc.
    var notes: String?
}

// Store in sidecar JSON: preset_name.json alongside preset_name.wav
```

---

## 8. Testing Recommendations

### 8.1 Unit Test Targets

**High Value Tests**:

1. `AggregateDeviceInspector.getSubDevices()` with various aggregate configurations
2. `ConvolutionEngine` with known impulse responses (verify correctness)
3. `SettingsManager` save/load round-trip
4. `HRIRManager.activatePreset()` with various channel counts

### 8.2 Integration Test Scenarios

**Critical Paths**:

1. Select aggregate → Select output → Start → Switch output → Verify audio continuity
2. Remove output device while running → Verify graceful error
3. Change aggregate device configuration → Verify app detects changes
4. Rapid output switching → Verify no crashes, no audio glitches

### 8.3 Performance Benchmarks

**Metrics to Track**:

1. Audio callback execution time (target: <50% of callback duration)
2. Settings save frequency (target: <1 save per second)
3. Device enumeration time (target: <100ms)
4. Memory allocations in audio callback (target: ZERO)

---

## 9. Priority Matrix

### Critical (Fix ASAP)

1. **Settings excessive saves**: Major I/O overhead
2. **Device disconnection handling**: App breaks silently
3. **Channel range validation**: Silent audio failure
4. **Thread safety in HRIRManager**: Potential crash

### High Priority (Next Sprint)

5. **Aggregate validation on selection**: Poor UX without it
6. **Device lookup optimization**: Noticeable lag with many devices
7. **Cached vs. dynamic device properties**: Staleness bugs

### Medium Priority (When Convenient)

8. **Error message improvements**: Better user communication
9. **Code deduplication**: Maintainability
10. **Output device validation**: Prevent invalid selections

### Low Priority (Nice to Have)

11. **Magic number cleanup**: Code clarity
12. **Latency monitoring**: Debugging tool
13. **Preset metadata**: Enhanced UX

---

## 10. Implementation Roadmap

### Sprint 1: Critical Fixes (3-5 days)

- [ ] Fix SettingsManager excessive saves (cache + debounce)
- [ ] Add device disconnection detection and handling
- [ ] Add thread-safe atomic swap for `rendererState`
- [ ] Add channel range validation with error messages

### Sprint 2: High-Priority Improvements (5-7 days)

- [ ] Optimize AggregateDeviceInspector device lookups
- [ ] Add aggregate device validation on selection
- [ ] Refactor AudioDevice to computed properties
- [ ] Add comprehensive error messages

### Sprint 3: Polish & Testing (5-7 days)

- [ ] Remove code duplication (CoreAudio queries)
- [ ] Add output device validation
- [ ] Write unit tests for critical paths
- [ ] Performance profiling and optimization

---

## 11. Conclusion

The codebase is **well-architected and already highly optimized** in the areas that matter most (zero-allocation audio callbacks, efficient FFT convolution). The main opportunities for improvement are:

### Quick Wins (High ROI)

1. **Fix settings saves** - 30 minutes of work, eliminates major I/O bottleneck
2. **Add device disconnect detection** - 1 hour of work, prevents confusing failures
3. **Thread-safe state swap** - 30 minutes of work, eliminates rare crash

### Strategic Improvements (Medium ROI)

4. **Device lookup optimization** - 2 hours of work, smoother UX
5. **Aggregate validation** - 2 hours of work, much better first-time UX
6. **Error message overhaul** - 3 hours of work, professional polish

### Nice to Have (Low ROI, High Effort)

7. AudioDevice refactor - 4+ hours, marginal benefit
8. Code deduplication - 3+ hours, maintainability only
9. Monitoring features - 2+ hours, debug tools only

**Recommended First Steps**:

1. Implement settings cache + debouncing (30 min)
2. Add device disconnect detection (1 hour)
3. Add thread-safe rendererState access (30 min)
4. Profile with Instruments to confirm zero allocations

The architecture is **production-ready**. These improvements would make it **exceptional**.

---

_End of Analysis_
