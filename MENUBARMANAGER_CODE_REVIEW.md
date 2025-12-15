# MenuBarManager.swift Code Review and Improvement Opportunities

**Date**: 2025-11-24
**File**: `MacHRIR/MenuBarManager.swift`
**Lines of Code**: 890
**Status**: Functional but contains technical debt from iterative development

---

## Executive Summary

The MenuBarManager has grown organically through trial-and-error development, resulting in:
- ✅ **Working device reconnection logic** (partially implemented)
- ⚠️ **Significant code duplication** (5+ instances of same filtering logic)
- ⚠️ **Inconsistent device persistence** (UIDs in memory, IDs on disk)
- ⚠️ **Two parallel restoration paths** that do similar things differently
- ⚠️ **Contradictory comments** about when to stop/restart audio

**Recommendation**: Refactor to consolidate logic and fully implement UID-based persistence.

---

## Critical Issues

### 🔴 Issue 1: Incomplete UID Migration

**Evidence**: Lines 36, 365, 395, 510, 514, 728 vs Lines 571-572

```swift
// TRACKING by UID in memory ✅
private var lastUserSelectedOutputUID: String?  // Line 36
lastUserSelectedOutputUID = firstOutput.uid     // Lines 365, 395, 510, etc.

// But SAVING by device ID to disk ❌
let settings = AppSettings(
    aggregateDeviceID: audioManager.aggregateDevice?.id,        // Line 571
    selectedOutputDeviceID: selectedOutputDevice?.device.id,    // Line 572
    // ...
)
```

**Impact**:
- UID tracking is lost on app restart
- Device reconnection only works within a single session
- Defeats the entire purpose of UID tracking

**Why This Happened**:
The refactoring was started (added `lastUserSelectedOutputUID`) but not completed (settings schema not updated).

**Fix**:
Implement Phase 2 of `DEVICE_PERSISTENCE_AND_RECONNECTION_REFACTOR.md` to update settings schema.

---

### 🔴 Issue 2: Duplicate Device Restoration Logic

**Two nearly identical functions** that restore user's preferred device:

#### Function A: `refreshAvailableOutputsIfNeeded()` (Lines 646-742)
- Triggered by: System device list changes (`deviceManager.$aggregateDevices`)
- Uses: `setupAudioUnit()` for restoration (stops/restarts audio)
- Lines of code: 96

#### Function B: `handleAggregateConfigurationChange()` (Lines 744-803)
- Triggered by: CoreAudio aggregate config change listener
- Uses: `setOutputChannels()` for restoration (no stop/restart)
- Lines of code: 59

**Key Differences**:
```swift
// Function A (Line 692)
try audioManager.setupAudioUnit(...)  // Reinitializes audio unit

// Function B (Line 778)
audioManager.setOutputChannels(channelRange)  // Just updates channels
```

**Why This is Confusing**:
1. Both functions do UID-based device restoration
2. But use different approaches (setupAudioUnit vs setOutputChannels)
3. Comments on Line 397 say "NO NEED TO STOP AUDIO!" but Function A does stop audio
4. Unclear which one is correct

**Root Cause**:
Two separate attempts to solve device reconnection, neither removed after the other was added.

**Impact**:
- Maintenance burden (bug fixes needed in 2 places)
- Inconsistent behavior depending on which listener fires first
- Race conditions possible

---

### 🟡 Issue 3: Contradictory Comments About Audio Restart

**Line 397**:
```swift
// Update output routing (NO NEED TO STOP AUDIO!)
let channelRange = output.startChannel..<(output.startChannel + 2)
audioManager.setOutputChannels(channelRange)
```

**But Lines 686-700** (in device reconnection logic):
```swift
// Need to reinitialize audio unit because device ID changed on reconnection
// Can't use setOutputChannels alone - it won't update the device reference
do {
    if let aggregate = audioManager.aggregateDevice {
        // Stop audio first
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        // ...
```

**Which is correct?**
- Line 397 suggests `setOutputChannels()` works without restart
- Lines 686-700 suggest `setupAudioUnit()` is needed for device ID changes

**Analysis**:
Both are correct, but for different scenarios:
- **Device ID unchanged**: `setOutputChannels()` works (manual switching)
- **Device ID changed**: `setupAudioUnit()` required (reconnection)

**Problem**: Code doesn't clearly distinguish these cases, leading to confusion.

---

## Code Quality Issues

### 🟡 Issue 4: Massive Code Duplication (Virtual Loopback Filtering)

**Duplicated 5 times** across the file:

1. **Lines 352-355** (selectAggregateDevice):
```swift
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

2. **Lines 496-499** (loadSettings):
```swift
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

3. **Lines 654-657** (refreshAvailableOutputsIfNeeded)
4. **Lines 756-759** (handleAggregateConfigurationChange)
5. **Lines 814-817** (refreshOutputChannelMapping)

**Plus empty-check fallback duplicated 5 times**:
```swift
if availableOutputs.isEmpty && !allOutputs.isEmpty {
    print("[MenuBarManager] Warning: All outputs were virtual loopback devices, showing all")
    availableOutputs = allOutputs
}
```

**Impact**:
- 30+ lines of duplicated code
- If filter logic changes (e.g., add "Loopback" to filter), must update 5 places
- Easy to miss updates, leading to inconsistencies

**Fix**: Extract to helper method.

---

### 🟡 Issue 5: Hardcoded Stereo Channel Range

**Repeated 11 times** throughout the file:
```swift
output.startChannel..<(output.startChannel + 2)
```

**Locations**: Lines 323, 370, 399, 521, 694, 730, 777, 825, 851

**Problems**:
- Magic number `2` assumes stereo output
- If future feature adds multi-channel output, must update 11 places
- Not clear what `+ 2` means without context

**Fix**: Extract to computed property or helper method:
```swift
extension SubDeviceInfo {
    var stereoChannelRange: Range<Int> {
        return startChannel..<(startChannel + 2)
    }
}
```

---

### 🟡 Issue 6: Debug Logging Left in Production Code

**Lines 666-668**:
```swift
print("[MenuBarManager] DEBUG (refresh): lastUserSelectedOutputUID = \(String(describing: lastUserSelectedOutputUID))")
print("[MenuBarManager] DEBUG (refresh): current selectedOutputDevice = \(String(describing: selectedOutputDevice?.device.id))")
print("[MenuBarManager] DEBUG (refresh): availableOutputs IDs = \(availableOutputs.map { $0.device.id })")
```

**Lines 674, 678, 710**: More DEBUG logs

**Lines 748-750**: More DEBUG logs in `handleAggregateConfigurationChange()`

**Impact**:
- Console spam for end users
- Performance overhead (string interpolation)
- Makes legitimate logs harder to find

**Fix**:
1. Remove DEBUG logs, or
2. Use conditional compilation:
```swift
#if DEBUG
print("[MenuBarManager] DEBUG: ...")
#endif
```

---

### 🟡 Issue 7: Two Listeners for Overlapping Events

**Listener 1**: Combine publisher (Lines 74-80)
```swift
deviceManager.$aggregateDevices
    .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
    .sink { [weak self] _ in
        self?.refreshAvailableOutputsIfNeeded()  // Calls Function A
        self?.updateMenu()
    }
```

**Listener 2**: CoreAudio property listener (Lines 595-619, 871-889)
```swift
AudioObjectAddPropertyListener(
    device.id,
    &propertyAddress,  // kAudioAggregateDevicePropertyFullSubDeviceList
    aggregateDeviceChangeCallback,
    // ...
)

// Callback invokes:
manager.handleAggregateConfigurationChange()  // Calls Function B
```

**Problem**:
- Both fire when aggregate device configuration changes
- Can fire at different times (~100ms apart based on LESSONS.md)
- Each calls a different restoration function
- Potential for race conditions or double-processing

**Questions**:
1. Why have both?
2. Which one is more reliable?
3. Can they conflict with each other?

**Likely Answer**:
- Publisher fires when system device list changes (device added/removed from system)
- Listener fires when aggregate config changes (sub-device added/removed from aggregate)
- These are related but distinct events

**Recommendation**: Document the distinction clearly, or consolidate.

---

### 🟡 Issue 8: Validation Filters, Then Selection Filters Again

**Validation (Lines 282-288)**:
```swift
private func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?) {
    do {
        let inputs = try inspector.getInputDevices(aggregate: device)
        let allOutputs = try inspector.getOutputDevices(aggregate: device)

        // Filter out virtual loopback devices for validation
        let outputs = allOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }
```

**Then Selection (Lines 348-355)**:
```swift
let allOutputs = try inspector.getOutputDevices(aggregate: device)

// Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

**Issue**:
- Filtering happens twice
- If validation passes but selection filters everything, inconsistency
- Code assumes both use same filter (but they're duplicated, so could diverge)

**Fix**: Extract filter, apply once before validation.

---

### 🟢 Issue 9: Unused Import

**Line 13**:
```swift
import CoreAudio
```

**Analysis**:
- File uses `AudioDevice` types, but those are defined in `AudioDevice.swift`
- CoreAudio types like `AudioObjectPropertyAddress` used in callback (line 599), but that's acceptable
- However, most CoreAudio operations are in `AggregateDeviceInspector` and `AudioDeviceManager`

**Verdict**: Probably needed for `AudioObjectPropertyAddress` and `AudioObjectAddPropertyListener`. Keep it.

**Not an issue**.

---

### 🟢 Issue 10: Inspector Strategy Not Optimal

**Line 46**:
```swift
inspector.missingDeviceStrategy = .skipMissing
```

**Per Refactoring Plan**: Should be `.skipWithWarning` for better diagnostics.

**Impact**: Low (still works, just less informative)

**Fix**: Change to `.skipWithWarning` and log skipped devices:
```swift
inspector.missingDeviceStrategy = .skipWithWarning

// After calling inspector methods:
if !inspector.lastSkippedDevices.isEmpty {
    print("[MenuBarManager] ⚠️ Skipped devices: \(inspector.lastSkippedDevices)")
}
```

---

## Architecture Issues

### 🟡 Issue 11: MenuBarManager Has Too Many Responsibilities

**Current responsibilities**:
1. Menu UI management (status bar, menu items)
2. Device lifecycle management (selection, validation, reconnection)
3. Settings persistence coordination
4. CoreAudio listener management
5. Audio engine state coordination
6. HRIR preset coordination
7. Error handling and user alerts

**Recommendation**: Extract device management into separate `DeviceCoordinator` class:

```swift
class DeviceCoordinator {
    private let inspector: AggregateDeviceInspector
    private let audioManager: AudioGraphManager
    private(set) var selectedAggregate: AudioDevice?
    private(set) var selectedOutput: SubDeviceInfo?
    private(set) var availableOutputs: [SubDeviceInfo]

    func selectAggregateDevice(_ device: AudioDevice) throws { ... }
    func selectOutputDevice(_ output: SubDeviceInfo) { ... }
    func handleDeviceReconnection() { ... }
    func validateAggregateDevice(_ device: AudioDevice) -> ValidationResult { ... }
}
```

This would reduce MenuBarManager from 890 lines to ~400-500 lines.

---

### 🟡 Issue 12: Inconsistent Error Handling

**Example 1** (Lines 384-386):
```swift
} catch {
    print("Failed to configure aggregate device: \(error)")
}
// No user feedback!
```

**Example 2** (Lines 329-336):
```swift
if !validation.valid {
    let alert = NSAlert()
    alert.messageText = "Invalid Aggregate Device"
    alert.informativeText = validation.reason ?? "Unknown error"
    alert.addButton(withTitle: "OK")
    alert.runModal()
    return
}
// User gets alert
```

**Problem**: Inconsistent - sometimes errors shown to user, sometimes silently logged.

**Recommendation**: Create error handling policy:
- **Configuration errors**: Show alert to user
- **Background errors** (reconnection failures): Log only, or use notification
- **Critical errors**: Show alert + disable functionality

---

### 🟡 Issue 13: Channel Range Calculations Not Validated

**Lines 323, 370, 399, etc.**:
```swift
outputChannelRange: output.startChannel..<(output.startChannel + 2)
```

**Risk**: What if device only has 1 channel? `startChannel + 2` could exceed available channels.

**Current code assumes**: All output devices have at least 2 channels (stereo).

**Validation exists** (lines 302-305):
```swift
let hasStereoOutput = outputs.contains {
    guard let range = $0.outputChannelRange else { return false }
    return (range.upperBound - range.lowerBound) >= 2
}
```

**But**: Validation is for aggregate, not per-output-device.

**Edge case**: Aggregate with mono device (1ch) + stereo device (2ch) would pass validation, but selecting mono device would create invalid range.

**Fix**: Add per-device validation or use `min(startChannel + 2, endChannel + 1)`.

---

## Positive Aspects (Don't Break These)

### ✅ Well-Structured Sections
- Clear MARK comments (Lines 277, 474, 593, 868)
- Logical grouping of related methods
- Separation of concerns (mostly)

### ✅ Good Debouncing
- Lines 561-565: Settings saves debounced (0.3s)
- Lines 74-80: Device changes debounced (100ms)
- Prevents excessive disk I/O and UI updates

### ✅ Proper Memory Management
- Lines 76, 90, 104, 120, 547, 563: Uses `[weak self]` in closures
- Line 589-591: Proper cleanup in `deinit`
- Unmanaged CoreAudio callbacks handled correctly (line 609)

### ✅ State Guards
- Lines 556-559: Prevents saves during restoration
- Lines 477-479: `isRestoringState` flag prevents observer loops
- Lines 622-624: Guards against removing non-existent listener

### ✅ User Experience
- Lines 127-133: Status icon updates (filled vs outline)
- Lines 262-263: Disables start button when devices not configured
- Lines 364-365, 395: Tracks user's preferred device

---

## Proposed Refactoring Plan

### Phase 1: Extract Duplicate Code (2 hours)

**1.1 Virtual Loopback Device Filter**
```swift
extension AggregateDeviceInspector.SubDeviceInfo {
    var isVirtualLoopback: Bool {
        let name = self.name.lowercased()
        return name.contains("blackhole") || name.contains("soundflower")
    }
}

private func filterVirtualLoopbackDevices(_ devices: [SubDeviceInfo]) -> [SubDeviceInfo] {
    let filtered = devices.filter { !$0.isVirtualLoopback }

    if filtered.isEmpty && !devices.isEmpty {
        print("[MenuBarManager] ⚠️ All outputs were virtual loopback devices, showing all")
        return devices
    }

    return filtered
}
```

Replace all 5 instances with:
```swift
availableOutputs = filterVirtualLoopbackDevices(allOutputs)
```

**1.2 Stereo Channel Range Helper**
```swift
extension AggregateDeviceInspector.SubDeviceInfo {
    func stereoChannelRange() -> Range<Int> {
        let maxChannel = outputChannelRange?.upperBound ?? (startChannel + 2)
        let endChannel = min(startChannel + 2, maxChannel)
        return startChannel..<endChannel
    }
}
```

Replace all 11 instances with:
```swift
outputChannelRange: output.stereoChannelRange()
```

---

### Phase 2: Consolidate Device Restoration Logic (3 hours)

**2.1 Create Unified Restoration Method**
```swift
private func restoreUserPreferredDevice(from outputs: [SubDeviceInfo]) {
    guard let userUID = lastUserSelectedOutputUID else { return }
    guard let preferredDevice = outputs.first(where: { $0.uid == userUID }) else { return }

    // Check if device ID changed (reconnection scenario)
    let deviceIDChanged = selectedOutputDevice?.device.id != preferredDevice.device.id

    if deviceIDChanged {
        // Device reconnected with new ID - must reinitialize audio unit
        restoreDeviceAfterReconnection(preferredDevice)
    } else {
        // Same device, just refresh channels (topology changed)
        refreshChannelMapping(for: preferredDevice)
    }
}

private func restoreDeviceAfterReconnection(_ device: SubDeviceInfo) {
    print("[MenuBarManager] Restoring reconnected device: \(device.name)")

    guard let aggregate = audioManager.aggregateDevice else { return }

    let wasRunning = audioManager.isRunning
    if wasRunning { audioManager.stop() }

    do {
        try audioManager.setupAudioUnit(
            aggregateDevice: aggregate,
            outputChannelRange: device.stereoChannelRange()
        )

        selectedOutputDevice = device

        if wasRunning { audioManager.start() }

        print("[MenuBarManager] ✅ Restored: \(device.name)")
    } catch {
        print("[MenuBarManager] ❌ Failed to restore: \(error)")
    }
}

private func refreshChannelMapping(for device: SubDeviceInfo) {
    print("[MenuBarManager] Refreshing channel mapping for: \(device.name)")
    selectedOutputDevice = device
    audioManager.setOutputChannels(device.stereoChannelRange())
}
```

**2.2 Simplify Both Listener Handlers**
```swift
private func refreshAvailableOutputsIfNeeded() {
    guard let device = audioManager.aggregateDevice else { return }

    do {
        let allOutputs = try inspector.getOutputDevices(aggregate: device)
        let newOutputs = filterVirtualLoopbackDevices(allOutputs)

        if newOutputs.count != availableOutputs.count {
            print("[MenuBarManager] Output count changed: \(availableOutputs.count) → \(newOutputs.count)")
            availableOutputs = newOutputs

            // Try to restore user's preferred device
            restoreUserPreferredDevice(from: availableOutputs)

            updateMenu()
        }
    } catch {
        print("[MenuBarManager] Failed to refresh outputs: \(error)")
    }
}

fileprivate func handleAggregateConfigurationChange() {
    // Delegate to the same logic
    refreshAvailableOutputsIfNeeded()
}
```

**Result**: Eliminates ~100 lines of duplicate code.

---

### Phase 3: Implement Full UID Persistence (2 hours)

**Follow** `DEVICE_PERSISTENCE_AND_RECONNECTION_REFACTOR.md` Phase 2:
- Update `AppSettings` to use UIDs
- Add migration from device IDs to UIDs
- Update `performSave()` to save UIDs
- Update `loadSettings()` to restore by UID

---

### Phase 4: Remove Debug Logging (30 minutes)

**4.1 Remove or conditionalize DEBUG logs**
```swift
#if DEBUG
private func logDebugInfo(_ message: String) {
    print("[MenuBarManager] DEBUG: \(message)")
}
#else
private func logDebugInfo(_ message: String) {
    // No-op in release
}
#endif
```

**4.2 Clean up log messages**
- Remove lines 666-668, 674, 678, 748-750, 766
- Keep essential logs (device selection, errors, restoration)

---

### Phase 5: Documentation and Comments (1 hour)

**5.1 Add Method Documentation**
```swift
/// Restores user's previously-selected output device after reconnection.
///
/// This method handles the case where a USB/Bluetooth device is disconnected and
/// reconnected, resulting in a new AudioDeviceID. It matches devices by UID
/// (persistent identifier) and reinitializes the audio unit if necessary.
///
/// - Parameter outputs: Available output devices to search
private func restoreUserPreferredDevice(from outputs: [SubDeviceInfo]) {
    // ...
}
```

**5.2 Add Architecture Comment**
```swift
// MARK: - Device Restoration Architecture
//
// Two CoreAudio events can trigger device restoration:
//
// 1. System Device Change (deviceManager.$aggregateDevices publisher)
//    - Fires when devices are added/removed from the system
//    - Slower (~100-500ms after actual change)
//    - More reliable for detecting reconnected devices
//
// 2. Aggregate Config Change (kAudioAggregateDevicePropertyFullSubDeviceList listener)
//    - Fires when aggregate's sub-device list changes
//    - Faster (~10-50ms after change)
//    - May fire before device is fully available
//
// Both call refreshAvailableOutputsIfNeeded() which:
// - Enumerates available outputs
// - Attempts to restore user's preferred device (by UID)
// - Falls back to first available device if preferred not found
```

**5.3 Clarify Audio Restart Comment**
```swift
// Update output routing
// NOTE: setOutputChannels() works without restarting audio ONLY if:
//   - The device ID hasn't changed
//   - We're just switching between different outputs in the same aggregate
// For device reconnection (new device ID), use setupAudioUnit() instead.
let channelRange = output.stereoChannelRange()
audioManager.setOutputChannels(channelRange)
```

---

## Testing Recommendations

After refactoring, test these scenarios:

### Device Reconnection
- [ ] Bluetooth headphones disconnect/reconnect while audio running
- [ ] USB device disconnect/reconnect while audio stopped
- [ ] Multiple rapid disconnect/reconnect cycles
- [ ] Reconnect after app restart

### Aggregate Device Changes
- [ ] Add/remove sub-device in Audio MIDI Setup while app running
- [ ] Disconnect middle sub-device (test channel shifting)
- [ ] Disconnect all outputs (should show error)
- [ ] Disconnect clock source device

### Edge Cases
- [ ] Select mono output device (should validate correctly)
- [ ] Aggregate with only virtual loopback devices
- [ ] Device name changes (firmware update) - should still work via UID
- [ ] Two identical devices (same model) - UID should distinguish them

---

## Summary of Improvements

| Issue | Priority | Effort | Impact |
|-------|----------|--------|--------|
| Incomplete UID migration | 🔴 High | 2h | High - Fixes persistence |
| Duplicate restoration logic | 🔴 High | 3h | High - Reduces bugs |
| Code duplication (filtering) | 🟡 Medium | 2h | Medium - Maintainability |
| Hardcoded channel ranges | 🟡 Medium | 1h | Medium - Future-proofing |
| Debug logging | 🟡 Medium | 0.5h | Low - Polish |
| Two overlapping listeners | 🟡 Medium | 1h | Low - Clarity |
| Documentation | 🟢 Low | 1h | Medium - Maintainability |

**Total Refactoring Effort**: ~10.5 hours

**Benefits**:
- 🎯 Complete UID-based persistence (survives reconnections)
- 🧹 ~150 lines of code removed (duplicates)
- 🐛 Fewer bugs from duplicate logic
- 📖 Clearer architecture
- 🔧 Easier to maintain

---

## Conclusion

MenuBarManager.swift is **functional but accumulated technical debt**. The main issues stem from:
1. **Incomplete refactoring** (UID tracking started but not finished)
2. **Two attempts to solve reconnection** (both kept, neither removed)
3. **Extensive code duplication** (5+ instances of same filter)

**Recommended Action**:
Follow the 5-phase refactoring plan above to consolidate logic and complete the UID migration. This will make the codebase more maintainable and fix persistent device selection across sessions.

**Priority**: Phase 2 (consolidate restoration) and Phase 3 (UID persistence) are most critical.
