# Device Persistence and Reconnection Refactoring Plan

**Date**: 2025-11-24
**Status**: Proposed
**Priority**: High - Affects all users with USB/Bluetooth devices
**Estimated Effort**: 4-6 hours implementation + 2-3 hours testing

---

## Executive Summary

This refactoring addresses two critical issues in MacHRIR's device management:

1. **Incorrect device persistence**: App stores `AudioDeviceID` values which change on device reconnection
2. **Aggregate device brittleness**: App crashes when aggregate devices have disconnected sub-devices

**Root Cause**: Misunderstanding of CoreAudio's device identification model.

**Solution**: Use device UIDs (persistent identifiers) instead of device IDs (runtime identifiers), and gracefully handle missing sub-devices.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Technical Background](#technical-background)
3. [Current Implementation Issues](#current-implementation-issues)
4. [Proposed Solution](#proposed-solution)
5. [Implementation Plan](#implementation-plan)
6. [Testing Strategy](#testing-strategy)
7. [Rollback Plan](#rollback-plan)
8. [References](#references)

---

## Problem Statement

### Problem 1: Device Settings Don't Persist Across Reconnections

**Scenario**:
1. User selects Bluetooth headphones as output device
2. User quits MacHRIR
3. User disconnects and reconnects headphones (or reboots Mac)
4. User launches MacHRIR
5. ❌ Previously selected device is not restored

**Why**: CoreAudio assigns new `AudioDeviceID` on reconnection. Stored device ID (e.g., `111`) no longer matches new ID (e.g., `144`).

### Problem 2: Aggregate Devices with Disconnected Sub-Devices Crash App

**Scenario**:
1. User creates aggregate device: BlackHole + Headphones + Speakers
2. User disconnects Speakers physically
3. User opens MacHRIR menu
4. ❌ App throws error: `Sub-device 'BuiltInHeadphoneOutputDevice' not found on system`

**Why**: `AggregateDeviceInspector` queries full sub-device list, then tries to look up each device. When a device is disconnected, lookup fails and throws exception.

---

## Technical Background

### CoreAudio Device Identification: ID vs UID

CoreAudio provides two identifiers for audio devices:

| Property | Type | Persistence | Use Case |
|----------|------|-------------|----------|
| **AudioDeviceID** | `UInt32` | ❌ Session-only | Runtime operations during current session |
| **DeviceUID** | `CFString` | ✅ Persistent | Settings storage, device restoration |

#### AudioDeviceID (Runtime Identifier)

```swift
// Example: 42, 111, 144
let deviceID: AudioDeviceID = 111
```

**Characteristics**:
- ✅ Fast lookup, efficient
- ❌ Changes on device reconnection (especially USB/Bluetooth)
- ❌ Changes on system reboot
- ❌ Not suitable for UserDefaults storage

**When to use**: Current session operations (setting audio units, querying properties)

#### DeviceUID (Persistent Identifier)

```swift
// Example: "AppleUSBAudioEngine:Manufacturer:Model:SerialNumber:Location"
let deviceUID: String = "BuiltInSpeakerDevice"
```

**Characteristics**:
- ✅ Stable across reboots
- ✅ Stable across reconnections
- ✅ Unique per device instance
- ⚠️ Not shareable between computers (may contain CPU-specific info)

**When to use**: UserDefaults storage, device selection persistence

#### Translation API

```swift
// UID → ID (for app launch restoration)
kAudioHardwarePropertyTranslateUIDToDevice

// ID → UID (for saving settings)
kAudioDevicePropertyDeviceUID
```

### Aggregate Device Sub-Device Lists

CoreAudio provides two properties for querying aggregate sub-devices:

| Property | Returns | Use Case |
|----------|---------|----------|
| `kAudioAggregateDevicePropertyFullSubDeviceList` | All configured sub-devices | Configuration inspection |
| `kAudioAggregateDevicePropertyActiveSubDeviceList` | Only connected sub-devices | Runtime device selection |

**Current code uses**: `FullSubDeviceList` (throws error on missing devices)
**Should also support**: Gracefully handling missing devices from full list

---

## Current Implementation Issues

### Issue 1: Settings Storage Uses Device IDs

**File**: `MacHRIR/SettingsManager.swift`

```swift
struct AppSettings: Codable {
    var aggregateDeviceID: UInt32?           // ❌ Runtime ID, not persistent
    var selectedOutputDeviceID: UInt32?      // ❌ Runtime ID, not persistent
    // ...
}
```

**Problem**: When devices reconnect with new IDs, restoration fails silently.

**Evidence**:
- Line 13-14: Stores `UInt32` device IDs
- Line 127-135: Helper methods assume ID stability
- Line 100-101: Logs show ID values being saved

### Issue 2: Device Restoration Uses ID Matching

**File**: `MacHRIR/MenuBarManager.swift`

```swift
// Line 433-436: Tries to find device by ID
if let deviceID = settings.aggregateDeviceID,
   let device = AudioDeviceManager.getAllDevices().first(where: { $0.id == deviceID }),
   inspector.isAggregateDevice(device) {
    // Restore device...
}
```

**Problem**: `$0.id == deviceID` fails when device ID changed.

### Issue 3: Aggregate Inspector Throws on Missing Devices

**File**: `MacHRIR/AggregateDeviceInspector.swift`

```swift
// Line 167-169: Hard error on missing device
guard let device = deviceLookup[uid] else {
    throw AggregateInspectorError.deviceNotFound(uid: uid)
}
```

**Problem**:
- Prevents app from showing aggregate with partial connectivity
- User cannot use remaining connected outputs
- No graceful degradation

### Issue 4: Menu Filtering Doesn't Check Device Health

**File**: `MacHRIR/MenuBarManager.swift`

```swift
// Line 141-142: Shows all aggregates regardless of connectivity
let allDevices = AudioDeviceManager.getAllDevices()
let aggregates = allDevices.filter { inspector.isAggregateDevice($0) }
```

**Problem**: Shows broken aggregates that will fail when selected.

---

## Proposed Solution

### Architecture Changes

```
┌─────────────────────────────────────────────────────────────┐
│                      USER INTERACTS                          │
│              (Selects "Sony Headphones")                     │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                   MenuBarManager                             │
│  • Stores: selectedOutputDeviceUID (String)                 │
│  • Saves: Device UID to SettingsManager                     │
│  • Resolves: UID → ID when needed via helper                │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  SettingsManager                             │
│  struct AppSettings {                                        │
│    var aggregateDeviceUID: String?        // ✅ Persistent  │
│    var selectedOutputDeviceUID: String?   // ✅ Persistent  │
│  }                                                           │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              AudioDeviceManager (NEW)                        │
│  • translateUIDToDevice(uid: String) -> AudioDevice?        │
│  • getDeviceUID(device: AudioDevice) -> String?             │
└─────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **UIDs for Persistence**: All UserDefaults storage uses UIDs
2. **IDs for Runtime**: AudioDeviceID used only during active session
3. **Lazy Resolution**: UID→ID translation happens on demand
4. **Graceful Degradation**: Missing devices are skipped, not fatal errors
5. **Health Checks**: Validate aggregate devices before presenting to user

---

## Implementation Plan

### Phase 1: Add UID Translation Helpers

**File**: `MacHRIR/AudioDevice.swift` (extend `AudioDeviceManager`)

**Task 1.1**: Add UID→Device translation

```swift
/// Translate device UID to AudioDevice (if currently available)
static func getDeviceByUID(_ uid: String) -> AudioDevice? {
    var uidString = uid as CFString
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceID: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        UInt32(MemoryLayout<CFString>.size),
        &uidString,
        &propertySize,
        &deviceID
    )

    guard status == noErr, deviceID != 0 else {
        return nil
    }

    return getDeviceInfo(deviceID: deviceID)
}
```

**Task 1.2**: Add Device→UID extraction

```swift
/// Get persistent UID for an AudioDevice
static func getDeviceUID(_ device: AudioDevice) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

    let status = AudioObjectGetPropertyData(
        device.id,
        &propertyAddress,
        0,
        nil,
        &size,
        &deviceUID
    )

    guard status == noErr, let uid = deviceUID?.takeRetainedValue() as String? else {
        return nil
    }

    return uid
}
```

**Task 1.3**: Add convenience property to AudioDevice struct

```swift
// In AudioDevice struct (line 14)
var uid: String? { AudioDeviceManager.getDeviceUID(self) }
```

**Testing Phase 1**:
- [ ] Query UID for built-in speakers
- [ ] Verify UID persistence after reboot
- [ ] Test UID→Device translation
- [ ] Test with USB/Bluetooth device disconnect/reconnect

---

### Phase 2: Update Settings Schema

**File**: `MacHRIR/SettingsManager.swift`

**Task 2.1**: Update AppSettings struct

```swift
struct AppSettings: Codable {
    // MIGRATION: Keep old fields for backward compatibility, but deprecated
    @available(*, deprecated, message: "Use aggregateDeviceUID instead")
    var aggregateDeviceID: UInt32?

    @available(*, deprecated, message: "Use selectedOutputDeviceUID instead")
    var selectedOutputDeviceID: UInt32?

    // NEW: Persistent identifiers
    var aggregateDeviceUID: String?
    var selectedOutputDeviceUID: String?

    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            aggregateDeviceID: nil,  // Keep for migration
            selectedOutputDeviceID: nil,  // Keep for migration
            aggregateDeviceUID: nil,
            selectedOutputDeviceUID: nil,
            activePresetID: nil,
            convolutionEnabled: false,
            autoStart: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
    }
}
```

**Task 2.2**: Add migration logic

```swift
private func loadSettingsFromDisk() -> AppSettings {
    print("[Settings] Loading settings from UserDefaults")

    guard let data = defaults.data(forKey: settingsKey) else {
        print("[Settings] No settings found in UserDefaults, using defaults")
        return .default
    }

    guard var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        print("[Settings] Failed to decode settings. Resetting to defaults.")
        return .default
    }

    // MIGRATION: Convert old device IDs to UIDs
    var needsMigration = false

    if settings.aggregateDeviceUID == nil, let oldID = settings.aggregateDeviceID {
        if let device = AudioDeviceManager.getAllDevices().first(where: { $0.id == oldID }),
           let uid = device.uid {
            print("[Settings] Migrating aggregate device ID \(oldID) → UID \(uid)")
            settings.aggregateDeviceUID = uid
            needsMigration = true
        }
    }

    if settings.selectedOutputDeviceUID == nil, let oldID = settings.selectedOutputDeviceID {
        if let device = AudioDeviceManager.getAllDevices().first(where: { $0.id == oldID }),
           let uid = device.uid {
            print("[Settings] Migrating output device ID \(oldID) → UID \(uid)")
            settings.selectedOutputDeviceUID = uid
            needsMigration = true
        }
    }

    // Save migrated settings
    if needsMigration {
        print("[Settings] Migration complete, saving updated settings")
        // Save synchronously during migration
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    return settings
}
```

**Task 2.3**: Update helper methods

```swift
func setAggregateDevice(_ device: AudioDevice) {
    guard let uid = device.uid else {
        print("[Settings] Warning: Could not get UID for device \(device.name)")
        return
    }
    var settings = loadSettings()
    settings.aggregateDeviceUID = uid
    saveSettings(settings)
}

func getAggregateDevice() -> AudioDevice? {
    guard let uid = loadSettings().aggregateDeviceUID else { return nil }
    return AudioDeviceManager.getDeviceByUID(uid)
}

func setOutputDevice(_ device: AudioDevice) {
    guard let uid = device.uid else {
        print("[Settings] Warning: Could not get UID for device \(device.name)")
        return
    }
    var settings = loadSettings()
    settings.selectedOutputDeviceUID = uid
    saveSettings(settings)
}

func getOutputDevice() -> AudioDevice? {
    guard let uid = loadSettings().selectedOutputDeviceUID else { return nil }
    return AudioDeviceManager.getDeviceByUID(uid)
}
```

**Task 2.4**: Update logging

```swift
private func flush() {
    guard let settings = cachedSettings else { return }

    print("[Settings] Saving settings to UserDefaults:")
    print("  - Aggregate Device UID: \(settings.aggregateDeviceUID ?? "nil")")
    print("  - Output Device UID: \(settings.selectedOutputDeviceUID ?? "nil")")
    print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
    print("  - Convolution Enabled: \(settings.convolutionEnabled)")
    print("  - Auto Start: \(settings.autoStart)")

    // ... rest of method unchanged
}
```

**Testing Phase 2**:
- [ ] Launch app with existing settings (should migrate)
- [ ] Verify migration logs appear
- [ ] Verify old device ID fields get converted to UIDs
- [ ] Test with no existing settings (fresh install)
- [ ] Verify backward compatibility if decoding fails

---

### Phase 3: Make Aggregate Inspector Tolerant of Missing Devices

**File**: `MacHRIR/AggregateDeviceInspector.swift`

**Task 3.1**: Add missing device handling strategy

```swift
class AggregateDeviceInspector {

    enum MissingDeviceStrategy {
        case throwError        // Current behavior - throw exception
        case skipMissing       // New behavior - skip and continue
        case skipWithWarning   // Skip and track for diagnostics
    }

    var missingDeviceStrategy: MissingDeviceStrategy = .skipWithWarning

    // Track devices that were skipped (for diagnostics)
    private(set) var lastSkippedDevices: [(uid: String, reason: String)] = []

    // ... rest of class
}
```

**Task 3.2**: Update buildChannelMap() to handle missing devices

```swift
private func buildChannelMap(subDeviceUIDs: [String], deviceLookup: [String: AudioDevice]) throws -> [SubDeviceInfo] {
    var subDevices: [SubDeviceInfo] = []
    var currentInputChannel = 0
    var currentOutputChannel = 0

    // Reset skipped devices list
    lastSkippedDevices = []

    for uid in subDeviceUIDs {
        guard let device = deviceLookup[uid] else {
            // Device not found - apply strategy
            switch missingDeviceStrategy {
            case .throwError:
                throw AggregateInspectorError.deviceNotFound(uid: uid)

            case .skipMissing:
                continue // Silently skip

            case .skipWithWarning:
                lastSkippedDevices.append((uid: uid, reason: "Device not connected"))
                print("[AggregateDeviceInspector] ⚠️ Skipping disconnected sub-device: \(uid)")
                continue
            }
        }

        let inputChannels = getDeviceChannelCount(device: device, isInput: true)
        let outputChannels = getDeviceChannelCount(device: device, isInput: false)

        var inputRange: Range<Int>? = nil
        var outputRange: Range<Int>? = nil

        // Calculate input range
        if inputChannels > 0 {
            inputRange = currentInputChannel..<(currentInputChannel + inputChannels)
            currentInputChannel += inputChannels
        }

        // Calculate output range
        if outputChannels > 0 {
            outputRange = currentOutputChannel..<(currentOutputChannel + outputChannels)
            currentOutputChannel += outputChannels
        }

        // Create single entry for device
        if inputRange != nil || outputRange != nil {
            subDevices.append(SubDeviceInfo(
                device: device,
                uid: uid,
                name: device.name,
                inputChannelRange: inputRange,
                outputChannelRange: outputRange
            ))
        }
    }

    return subDevices
}
```

**Task 3.3**: Add device health check methods

```swift
/// Check if aggregate device has at least one valid output device
func hasValidOutputs(aggregate: AudioDevice) -> Bool {
    do {
        let outputs = try getOutputDevices(aggregate: aggregate)
        return !outputs.isEmpty
    } catch {
        return false
    }
}

/// Check if aggregate device has at least one valid input device
func hasValidInputs(aggregate: AudioDevice) -> Bool {
    do {
        let inputs = try getInputDevices(aggregate: aggregate)
        return !inputs.isEmpty
    } catch {
        return false
    }
}

/// Get diagnostic info about aggregate device health
func getDeviceHealth(aggregate: AudioDevice) -> (connected: Int, missing: Int, missingUIDs: [String]) {
    lastSkippedDevices = []
    let originalStrategy = missingDeviceStrategy
    missingDeviceStrategy = .skipWithWarning

    defer { missingDeviceStrategy = originalStrategy }

    do {
        let devices = try getSubDevices(aggregate: aggregate)
        return (
            connected: devices.count,
            missing: lastSkippedDevices.count,
            missingUIDs: lastSkippedDevices.map { $0.uid }
        )
    } catch {
        return (connected: 0, missing: 0, missingUIDs: [])
    }
}

/// Check if all sub-devices are connected (no missing devices)
func isFullyConnected(aggregate: AudioDevice) -> Bool {
    let health = getDeviceHealth(aggregate: aggregate)
    return health.missing == 0
}
```

**Testing Phase 3**:
- [ ] Create aggregate with 3 sub-devices
- [ ] Disconnect one sub-device
- [ ] Verify `getSubDevices()` returns only connected devices
- [ ] Verify `lastSkippedDevices` contains missing device UID
- [ ] Check `getDeviceHealth()` reports correct counts
- [ ] Verify no exceptions thrown

---

### Phase 4: Update MenuBarManager Device Restoration

**File**: `MacHRIR/MenuBarManager.swift`

**Task 4.1**: Configure inspector in init()

```swift
override init() {
    super.init()

    // Configure inspector to skip missing devices gracefully
    inspector.missingDeviceStrategy = .skipWithWarning

    // Connect managers
    audioManager.hrirManager = hrirManager

    setupStatusItem()
    setupObservers()

    waitForDevicesAndInitialize()
}
```

**Task 4.2**: Add UID-based device lookup helper

```swift
// Add as private method in MenuBarManager
private func findOutputDeviceByUID(_ uid: String, in outputs: [AggregateDeviceInspector.SubDeviceInfo]) -> AggregateDeviceInspector.SubDeviceInfo? {
    // First try exact UID match
    if let match = outputs.first(where: { $0.uid == uid }) {
        return match
    }

    // Fallback: try to match by device name (less reliable but better than nothing)
    if let targetDevice = AudioDeviceManager.getDeviceByUID(uid) {
        return outputs.first(where: { $0.device.name == targetDevice.name })
    }

    return nil
}
```

**Task 4.3**: Update loadSettings() to use UIDs

```swift
@discardableResult
private func loadSettings() -> AppSettings {
    print("[MenuBarManager] Loading settings...")
    isRestoringState = true

    let settings = settingsManager.loadSettings()

    // Restore aggregate device by UID
    if let deviceUID = settings.aggregateDeviceUID,
       let device = AudioDeviceManager.getDeviceByUID(deviceUID),
       inspector.isAggregateDevice(device) {

        print("[MenuBarManager] Restoring aggregate device: \(device.name) (UID: \(deviceUID))")

        // Check health before using
        let health = inspector.getDeviceHealth(aggregate: device)
        print("[MenuBarManager] Device health: \(health.connected) connected, \(health.missing) missing")

        if health.missing > 0 {
            print("[MenuBarManager] ⚠️ Missing sub-devices: \(health.missingUIDs)")
        }

        audioManager.selectAggregateDevice(device)

        // Load available outputs (only connected devices)
        do {
            availableOutputs = try inspector.getOutputDevices(aggregate: device)

            // Filter out virtual loopback devices
            availableOutputs = availableOutputs.filter { output in
                let name = output.name.lowercased()
                return !name.contains("blackhole") && !name.contains("soundflower")
            }

            print("[MenuBarManager] Available outputs: \(availableOutputs.map { $0.name })")

            // Restore selected output device by UID
            if let outputUID = settings.selectedOutputDeviceUID,
               let output = findOutputDeviceByUID(outputUID, in: availableOutputs) {
                print("[MenuBarManager] Restoring output device: \(output.name) (UID: \(outputUID))")
                selectedOutputDevice = output
            } else if let firstOutput = availableOutputs.first {
                // Fallback to first available output
                print("[MenuBarManager] ⚠️ Could not restore previous output, using: \(firstOutput.name)")
                selectedOutputDevice = firstOutput
            } else {
                print("[MenuBarManager] ❌ No output devices available")
                selectedOutputDevice = nil
            }

            // Setup audio graph
            if let output = selectedOutputDevice {
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: output.startChannel..<(output.startChannel + 2)
                )
            }

        } catch {
            print("[MenuBarManager] ❌ Failed to restore audio configuration: \(error)")
        }
    } else if settings.aggregateDeviceUID != nil {
        print("[MenuBarManager] ⚠️ Could not find previously selected aggregate device")
    }

    // Restore preset
    if let presetID = settings.activePresetID,
       let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
        print("[MenuBarManager] Restoring preset: \(preset.name)")
        let sampleRate = 48000.0
        let inputLayout = InputLayout.detect(channelCount: 2)
        hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
    }

    // Restore convolution
    print("[MenuBarManager] Restoring convolution: \(settings.convolutionEnabled)")
    hrirManager.convolutionEnabled = settings.convolutionEnabled

    // Allow observers to fire before enabling saves
    DispatchQueue.main.async { [weak self] in
        self?.isRestoringState = false
        print("[MenuBarManager] Restoration complete, saves now enabled")
    }

    return settings
}
```

**Task 4.4**: Update performSave() to use UIDs

```swift
private func performSave() {
    print("[MenuBarManager] Saving settings...")

    let aggregateUID = audioManager.aggregateDevice?.uid
    let outputUID = selectedOutputDevice?.device.uid

    if let aggUID = aggregateUID {
        print("[MenuBarManager] Saving aggregate UID: \(aggUID)")
    }
    if let outUID = outputUID {
        print("[MenuBarManager] Saving output UID: \(outUID)")
    }

    let settings = AppSettings(
        aggregateDeviceID: nil,  // Deprecated, leave nil
        selectedOutputDeviceID: nil,  // Deprecated, leave nil
        aggregateDeviceUID: aggregateUID,
        selectedOutputDeviceUID: outputUID,
        activePresetID: hrirManager.activePreset?.id,
        convolutionEnabled: hrirManager.convolutionEnabled,
        autoStart: audioManager.isRunning,
        bufferSize: 65536,
        targetSampleRate: 48000.0
    )
    settingsManager.saveSettings(settings)
}
```

**Task 4.5**: Update device selection to save UIDs

```swift
@objc private func selectOutputDevice(_ sender: NSMenuItem) {
    guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else { return }

    print("[MenuBarManager] User selected output: \(output.name) (UID: \(output.uid))")

    selectedOutputDevice = output

    // Update output routing (NO NEED TO STOP AUDIO!)
    let channelRange = output.startChannel..<(output.startChannel + 2)
    audioManager.setOutputChannels(channelRange)

    updateMenu()
    saveSettings()  // This now saves the UID via performSave()
}
```

**Task 4.6**: Filter aggregate device list in updateMenu()

```swift
// Line 141-156: Update aggregate device filtering
let allDevices = AudioDeviceManager.getAllDevices()
let aggregates = allDevices.filter { device in
    guard inspector.isAggregateDevice(device) else { return false }

    // Only show aggregates that have at least one valid output
    guard inspector.hasValidOutputs(aggregate: device) else {
        print("[MenuBarManager] Filtering out aggregate '\(device.name)' - no valid outputs")
        return false
    }

    return true
}
```

**Task 4.7**: Add diagnostic logging to device selection

```swift
@objc private func selectAggregateDevice(_ sender: NSMenuItem) {
    guard let device = sender.representedObject as? AudioDevice else { return }

    // Log device health
    let health = inspector.getDeviceHealth(aggregate: device)
    print("[MenuBarManager] Aggregate '\(device.name)': \(health.connected) connected, \(health.missing) missing")
    if health.missing > 0 {
        print("[MenuBarManager] Missing devices: \(health.missingUIDs)")
    }

    // Validate first
    let validation = validateAggregateDevice(device)
    if !validation.valid {
        let alert = NSAlert()
        alert.messageText = "Invalid Aggregate Device"
        alert.informativeText = validation.reason ?? "Unknown error"
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return
    }

    // ... rest of method unchanged
}
```

**Task 4.8**: Update validation messages

```swift
private func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?) {
    do {
        let inputs = try inspector.getInputDevices(aggregate: device)
        let outputs = try inspector.getOutputDevices(aggregate: device)

        print("[MenuBarManager] Validation: \(inputs.count) inputs, \(outputs.count) outputs available")

        if inputs.isEmpty {
            return (false, "Aggregate device '\(device.name)' has no connected input devices.\n\nPlease reconnect your input device or update the aggregate in Audio MIDI Setup.")
        }

        if outputs.isEmpty {
            return (false, "Aggregate device '\(device.name)' has no connected output devices.\n\nPlease reconnect your output devices or update the aggregate in Audio MIDI Setup.")
        }

        // Check for at least stereo output capability
        let hasStereoOutput = outputs.contains {
            guard let range = $0.outputChannelRange else { return false }
            return (range.upperBound - range.lowerBound) >= 2
        }

        if !hasStereoOutput {
            return (false, "Aggregate device '\(device.name)' has no stereo output.\n\nAt least one connected output device must have 2+ channels.")
        }

        return (true, nil)
    } catch {
        return (false, "Could not inspect aggregate device: \(error.localizedDescription)")
    }
}
```

**Testing Phase 4**:
- [ ] Launch app with existing settings
- [ ] Verify aggregate device restored by UID
- [ ] Verify output device restored by UID
- [ ] Disconnect output device
- [ ] Relaunch app
- [ ] Verify graceful fallback to first available output
- [ ] Reconnect device
- [ ] Relaunch app
- [ ] Verify original device is restored (even with new device ID)

---

### Phase 5: Add Device Reconnection Monitoring (Optional Enhancement)

**File**: `MacHRIR/MenuBarManager.swift`

**Task 5.1**: Add dynamic restoration on device reconnection

```swift
private func setupObservers() {
    // ... existing observers ...

    // Watch for system device changes (devices added/removed)
    deviceManager.$outputDevices
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.handleDeviceTopologyChange()
        }
        .store(in: &cancellables)
}

private func handleDeviceTopologyChange() {
    print("[MenuBarManager] Device topology changed, checking for reconnections...")

    guard let aggregate = audioManager.aggregateDevice else {
        return
    }

    // Refresh available outputs
    do {
        let newOutputs = try inspector.getOutputDevices(aggregate: aggregate)

        // Filter virtual loopback devices
        let filteredOutputs = newOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }

        // Check if outputs changed
        let oldCount = availableOutputs.count
        availableOutputs = filteredOutputs

        if availableOutputs.count != oldCount {
            print("[MenuBarManager] Output count changed: \(oldCount) → \(availableOutputs.count)")
            updateMenu()

            // Try to restore user's preferred device if it came back
            if let settings = try? settingsManager.loadSettings(),
               let preferredUID = settings.selectedOutputDeviceUID,
               let restoredOutput = findOutputDeviceByUID(preferredUID, in: availableOutputs),
               selectedOutputDevice?.device.id != restoredOutput.device.id {

                print("[MenuBarManager] ✅ Restoring reconnected device: \(restoredOutput.name)")

                // Need to reinitialize audio unit because device ID changed
                let wasRunning = audioManager.isRunning
                if wasRunning {
                    audioManager.stop()
                }

                selectedOutputDevice = restoredOutput

                do {
                    try audioManager.setupAudioUnit(
                        aggregateDevice: aggregate,
                        outputChannelRange: restoredOutput.startChannel..<(restoredOutput.startChannel + 2)
                    )

                    if wasRunning {
                        audioManager.start()
                    }

                    updateMenu()
                } catch {
                    print("[MenuBarManager] ❌ Failed to restore audio unit: \(error)")
                }
            }
        }
    } catch {
        print("[MenuBarManager] Failed to refresh outputs: \(error)")
    }
}
```

**Testing Phase 5**:
- [ ] Start audio with Bluetooth headphones
- [ ] Disconnect headphones
- [ ] Verify app continues with fallback device
- [ ] Reconnect headphones
- [ ] Verify app automatically switches back to headphones
- [ ] Check audio continues without user intervention

---

## Testing Strategy

### Test Suite 1: Device Persistence

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| **T1.1** Fresh Install | 1. Delete UserDefaults<br>2. Launch app<br>3. Select devices<br>4. Quit & relaunch | Settings restored |
| **T1.2** Device Reconnect | 1. Select USB device<br>2. Note device ID in logs<br>3. Disconnect & reconnect<br>4. Relaunch app | Device restored despite new ID |
| **T1.3** Bluetooth Reconnect | 1. Select Bluetooth device<br>2. Quit app<br>3. Disable/enable Bluetooth<br>4. Relaunch app | Device restored |
| **T1.4** System Reboot | 1. Select devices<br>2. Reboot Mac<br>3. Launch app | All settings restored |
| **T1.5** Migration | 1. Have old settings (device IDs)<br>2. Launch new version | Migrates to UIDs automatically |

### Test Suite 2: Aggregate Device Handling

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| **T2.1** Partial Disconnect | 1. Aggregate with 3 devices<br>2. Disconnect 1 output | Shows other 2 outputs, no crash |
| **T2.2** Input Disconnect | 1. Aggregate with BlackHole input<br>2. "Disconnect" input | Error message, cannot use aggregate |
| **T2.3** All Outputs Disconnected | 1. Disconnect all output devices | Aggregate filtered from menu |
| **T2.4** Middle Device Disconnect | 1. Dev A (ch 0-1) + Dev B (ch 2-3) + Dev C (ch 4-5)<br>2. Disconnect Dev B | Dev C channels still correct |
| **T2.5** Clock Source Disconnect | 1. Create aggregate<br>2. Set device as clock source<br>3. Disconnect that device | Observe behavior, document |

### Test Suite 3: Edge Cases

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| **T3.1** Device Name Change | 1. Save device settings<br>2. Change device name in system<br>3. Relaunch | Still works (UID unchanged) |
| **T3.2** Duplicate Device Names | 1. Two identical USB devices<br>2. Select one<br>3. Reconnect both | Correct device selected (UID unique) |
| **T3.3** Virtual Loopback Filter | 1. Aggregate with BlackHole | BlackHole not shown in output list |
| **T3.4** Rapid Reconnection | 1. Disconnect/reconnect quickly<br>2. Multiple times | Stable, no crashes |
| **T3.5** Invalid UID in Settings | 1. Manually corrupt settings<br>2. Put fake UID | Graceful fallback, no crash |

### Test Suite 4: Performance

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| **T4.1** App Launch Time | 1. Measure launch time before/after | No significant regression |
| **T4.2** Menu Open Performance | 1. Open menu with 10+ aggregates | Opens quickly (<500ms) |
| **T4.3** Device Change Latency | 1. Switch output devices | <100ms switchover |
| **T4.4** UID Resolution Cache | 1. Repeatedly query same UID | Fast (check if CoreAudio caches) |

---

## Rollback Plan

### If Critical Issues Found

**Step 1**: Revert to device ID storage
```swift
// In SettingsManager.swift
struct AppSettings: Codable {
    var aggregateDeviceID: UInt32?  // Restore primary
    var selectedOutputDeviceID: UInt32?  // Restore primary
    // Keep UID fields but don't use them
}
```

**Step 2**: Disable missing device tolerance
```swift
// In MenuBarManager.init()
inspector.missingDeviceStrategy = .throwError  // Revert to old behavior
```

**Step 3**: Deploy hotfix
- Users keep their settings
- App reverts to pre-refactor behavior
- Fix root cause and re-deploy

### Data Safety

✅ **Settings are forward/backward compatible**:
- Old version can read new settings (ignores unknown fields)
- New version can read old settings (migration code handles conversion)
- No data loss on version downgrade

---

## Success Criteria

### Must Have (P0)
- ✅ Device settings persist across app restarts
- ✅ Device settings persist across device reconnections
- ✅ Aggregate devices with missing sub-devices don't crash app
- ✅ Migration from old settings schema succeeds

### Should Have (P1)
- ✅ User's preferred device auto-restores on reconnection
- ✅ Clear error messages when devices unavailable
- ✅ Virtual loopback devices filtered from output list

### Nice to Have (P2)
- ✅ Diagnostic health check in menu
- ✅ User notification when device reconnects
- ✅ Comprehensive logging for debugging

---

## Timeline Estimate

| Phase | Tasks | Estimated Time |
|-------|-------|----------------|
| Phase 1 | UID translation helpers | 1 hour |
| Phase 2 | Settings schema + migration | 1-1.5 hours |
| Phase 3 | Aggregate inspector tolerance | 1 hour |
| Phase 4 | MenuBarManager updates | 1.5-2 hours |
| Phase 5 | Reconnection monitoring (optional) | 1 hour |
| **Total Implementation** | | **5.5-6.5 hours** |
| Testing | All test suites | 2-3 hours |
| **Grand Total** | | **7.5-9.5 hours** |

---

## References

### Apple Documentation
- [AudioDeviceID Reference](https://developer.apple.com/documentation/coreaudio/audiodeviceid)
- Core Audio Properties: `kAudioDevicePropertyDeviceUID`, `kAudioHardwarePropertyTranslateUIDToDevice`

### Stack Overflow Discussions
- [What is the use case for kAudioHardwarePropertyTranslateUIDToDevice](https://stackoverflow.com/questions/30486818/what-is-the-user-case-for-kaudiohardwarepropertytranslateuidtodevice)
- [Core Audio and the Phantom Device ID](https://stackoverflow.com/questions/8936434/core-audio-and-the-phantom-device-id)
- [How to detect when an Audio Device is disconnected in CoreAudio](https://stackoverflow.com/questions/23350779/how-to-detect-when-an-audio-device-is-disconnected-in-coreaudio)

### Related Documents
- `LESSONS.md` - Original problem documentation (needs correction)
- `AGGREGATE_DEVICE_GRACEFUL_DEGRADATION_PLAN.md` - Original missing device plan
- `CLAUDE.md` - Project architecture reference

---

## Future Enhancements

### Post-Refactor Improvements
1. **UID-based device matching in audio graph setup**
   - Currently `AudioGraphManager` works with device IDs directly
   - Could be refactored to accept UIDs and resolve internally

2. **Persistent device preferences per preset**
   - Store preferred output device per HRIR preset
   - Auto-switch when preset changes

3. **Smart device selection heuristics**
   - Prefer USB/Bluetooth over built-in
   - Remember per-context preferences (e.g., "gaming" vs "music")

4. **Device disconnection notifications**
   - Show user notification when preferred device disconnects
   - Option to auto-pause or switch to fallback

5. **Aggregate device wizard**
   - Built-in UI to create/modify aggregate devices
   - Eliminate need for Audio MIDI Setup

---

**Document Version**: 1.0
**Last Updated**: 2025-11-24
**Author**: System Architecture Review
**Status**: Ready for Implementation
