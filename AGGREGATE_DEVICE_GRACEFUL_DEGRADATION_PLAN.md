# Aggregate Device Graceful Degradation - Implementation Plan

## Problem Statement

When a physical device that's part of an aggregate device is disconnected:
- It appears "greyed out" in Audio MIDI Setup
- MacHRIR throws error: `Sub-device 'BuiltInHeadphoneOutputDevice' not found on system`
- The entire aggregate device becomes unusable in MacHRIR

## Proposed Solution

**Graceful degradation**: Skip missing sub-devices and only show/use active devices that are currently connected.

## Technical Feasibility Analysis

### What We Know
1. **Error Location**: `AggregateDeviceInspector.buildChannelMap()` line 168 throws `deviceNotFound` when a UID doesn't exist in `deviceLookup`
2. **The UID list is still valid**: `getSubDeviceUIDs()` successfully returns ALL UIDs (including disconnected devices)
3. **Active devices can be identified**: By checking if `deviceLookup[uid]` returns nil

### What We Don't Know (Testing Required)
1. **Will CoreAudio allow aggregate device to be used?** When we set it on the audio unit via `kAudioOutputUnitProperty_CurrentDevice`, will it:
   - ✅ Work with only connected sub-devices
   - ❌ Refuse to activate (throw error during `AudioUnitInitialize()`)
   - ❌ Activate but fail on `AudioOutputUnitStart()`
   - ⚠️ Partially work with undefined behavior

2. **Channel numbering**: When a middle device is disconnected, do channel numbers:
   - Stay at original positions (gaps in numbering)
   - Shift down to fill gaps

## Implementation Plan

### Phase 1: Make Inspector Tolerant of Missing Devices

**File**: `MacHRIR/AggregateDeviceInspector.swift`

#### Step 1.1: Add Error Handling Strategy
Add configuration option to `AggregateDeviceInspector`:

```swift
class AggregateDeviceInspector {

    enum MissingDeviceStrategy {
        case throwError        // Current behavior
        case skipMissing       // New behavior - ignore disconnected devices
    }

    var missingDeviceStrategy: MissingDeviceStrategy = .skipMissing

    // Track skipped devices for logging/debugging
    private(set) var lastSkippedDevices: [(uid: String, reason: String)] = []

    // ... rest of class
}
```

#### Step 1.2: Modify `buildChannelMap()` to Skip Missing Devices

**Location**: Lines 161-202

**Changes**:
```swift
private func buildChannelMap(subDeviceUIDs: [String], deviceLookup: [String: AudioDevice]) throws -> [SubDeviceInfo] {
    var subDevices: [SubDeviceInfo] = []
    var currentInputChannel = 0
    var currentOutputChannel = 0

    // Reset skipped devices
    lastSkippedDevices = []

    for uid in subDeviceUIDs {
        guard let device = deviceLookup[uid] else {
            // Device not found - apply strategy
            switch missingDeviceStrategy {
            case .throwError:
                throw AggregateInspectorError.deviceNotFound(uid: uid)

            case .skipMissing:
                // Log and skip
                lastSkippedDevices.append((uid: uid, reason: "Device not connected"))
                print("[AggregateDeviceInspector] Skipping disconnected device: \(uid)")
                continue // Skip this device, move to next
            }
        }

        // Rest of the logic remains the same...
        let inputChannels = getDeviceChannelCount(device: device, isInput: true)
        let outputChannels = getDeviceChannelCount(device: device, isInput: false)

        // ... (unchanged)
    }

    return subDevices
}
```

#### Step 1.3: Add Helper to Check Device Health

Add method to validate if aggregate is usable:

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

/// Get diagnostic info about aggregate device
func getDeviceHealth(aggregate: AudioDevice) -> (connected: Int, missing: Int, missingUIDs: [String]) {
    lastSkippedDevices = []
    let originalStrategy = missingDeviceStrategy
    missingDeviceStrategy = .skipMissing

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
```

---

### Phase 2: Update Device Filtering Logic

**File**: `MacHRIR/MenuBarManager.swift`

#### Step 2.1: Configure Inspector

**Location**: Line 23 (where inspector is initialized)

```swift
private let inspector = AggregateDeviceInspector()

override init() {
    super.init()

    // Configure inspector to skip missing devices
    inspector.missingDeviceStrategy = .skipMissing

    // ... rest of init
}
```

#### Step 2.2: Update Menu Device List to Show Only Valid Aggregates

**Location**: Lines 141-156 (where aggregate devices are listed)

**Current code**:
```swift
let allDevices = AudioDeviceManager.getAllDevices()
let aggregates = allDevices.filter { inspector.isAggregateDevice($0) }
```

**Change to**:
```swift
let allDevices = AudioDeviceManager.getAllDevices()
let aggregates = allDevices.filter { device in
    guard inspector.isAggregateDevice(device) else { return false }

    // Only show aggregates that have at least one valid output
    return inspector.hasValidOutputs(aggregate: device)
}
```

#### Step 2.3: Add Diagnostic Logging When Selecting Device

**Location**: Line 290 in `selectAggregateDevice()`

Before validation, add:

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
    // ... rest of method
}
```

#### Step 2.4: Update Validation Logic

**Location**: Lines 260-288 `validateAggregateDevice()`

The method already uses `getInputDevices()` and `getOutputDevices()` which will now automatically skip missing devices. No changes needed here, but add logging:

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

        // ... rest of validation (unchanged)

    } catch {
        return (false, "Could not inspect aggregate device: \(error.localizedDescription)")
    }
}
```

---

### Phase 3: Testing & Observing Behavior

#### Test Case 1: Select Aggregate with Missing Device
**Setup**:
1. Create aggregate with: BlackHole 2ch + Headphones + Speakers
2. Set BlackHole as clock source
3. Disconnect one output device physically (or simulate)

**Test**:
1. Launch MacHRIR
2. Select the aggregate device
3. Observe console logs
4. Try to start audio engine

**Expected Results**:
- ✅ Aggregate shows in device list
- ✅ Only connected outputs show in Output Device submenu
- ❓ Audio engine starts successfully (UNKNOWN - needs testing)

**Log what to observe**:
```
[AggregateDeviceInspector] Skipping disconnected device: <UID>
[MenuBarManager] Aggregate 'MyAggr': 2 connected, 1 missing
[MenuBarManager] Missing devices: [<UID>]
[MenuBarManager] Validation: 1 inputs, 2 outputs available
```

#### Test Case 2: Try to Use the Aggregate
**After Test Case 1**:
1. Select an output device from available outputs
2. Click "Start Audio Engine"

**Observe**:
- Does `AudioUnitInitialize()` succeed?
- Does `AudioOutputUnitStart()` succeed?
- Does audio flow correctly?
- Are channel numbers correct?

**Where to add debug logging**:
`MacHRIR/AudioGraphManager.swift` - Add logs in:
- `setupAudioUnit()` before/after `AudioUnitInitialize()`
- `start()` before/after `AudioOutputUnitStart()`

#### Test Case 3: Channel Numbering with Gaps
**Setup**:
1. Aggregate: Device A (2ch) + Device B (2ch) + Device C (2ch)
2. Disconnect Device B (the middle one)

**Test**:
1. Check what channels Device C reports
2. Expected original: channels 4-5
3. Actual behavior: ??? (needs testing)

**Add logging in `buildChannelMap()`**:
```swift
print("[AggregateDeviceInspector] Device '\(device.name)': Input[\(inputRange)], Output[\(outputRange)]")
```

---

### Phase 4: Handle CoreAudio Failures (If Needed)

**IF Test Case 2 shows that CoreAudio refuses to use the aggregate device**, add fallback:

#### Option A: Error at Startup with Clear Message

In `AudioGraphManager.setupAudioUnit()`, catch initialization failure:

```swift
func setupAudioUnit(aggregateDevice: AudioDevice, outputChannelRange: Range<Int>) throws {
    // ... existing setup code ...

    // Try to initialize
    let status = AudioUnitInitialize(outputUnit)
    guard status == noErr else {
        // Check if this is due to aggregate device with missing sub-devices
        if inspector.hasPartiallyDisconnectedDevices(aggregate: aggregateDevice) {
            throw AudioGraphError.aggregateDevicePartiallyConnected(
                message: "Cannot use aggregate device - some sub-devices are disconnected. Please reconnect all devices or recreate the aggregate."
            )
        } else {
            throw AudioGraphError.audioUnitError(status)
        }
    }
}
```

#### Option B: Filter Out Broken Aggregates Entirely

In `MenuBarManager.updateMenu()`, don't just check `hasValidOutputs`, also verify the device can actually be used:

```swift
let aggregates = allDevices.filter { device in
    guard inspector.isAggregateDevice(device) else { return false }
    guard inspector.hasValidOutputs(aggregate: device) else { return false }

    // Actually try to use the device (expensive - only on menu open)
    return canUseAggregateDevice(device)
}

private func canUseAggregateDevice(_ device: AudioDevice) -> Bool {
    // Try to create a test audio unit with this device
    // If it fails, don't show in list
    // This is a more aggressive filter
    // Implementation details depend on test results
}
```

---

## Summary of Changes

### Files Modified
1. ✏️ **AggregateDeviceInspector.swift**
   - Add `MissingDeviceStrategy` enum
   - Add `missingDeviceStrategy` property
   - Add `lastSkippedDevices` tracking
   - Modify `buildChannelMap()` to skip missing devices instead of throwing
   - Add `hasValidOutputs()`, `hasValidInputs()`, `getDeviceHealth()` helpers

2. ✏️ **MenuBarManager.swift**
   - Set `inspector.missingDeviceStrategy = .skipMissing` in init
   - Filter aggregate device list to only show devices with valid outputs
   - Add diagnostic logging in `selectAggregateDevice()`
   - Update validation error messages to mention "connected" devices
   - (Optional) Add test helper `canUseAggregateDevice()` if Phase 4 is needed

3. 🐛 **AudioGraphManager.swift** (Optional - Phase 4 only)
   - Add better error handling for aggregate device initialization
   - Add specific error case for partially connected aggregates

### Testing Checklist
- [ ] Create aggregate device with 3+ sub-devices
- [ ] Verify all devices work when connected
- [ ] Disconnect one output device
- [ ] Verify aggregate still appears in device list
- [ ] Verify only connected devices show in output list
- [ ] **Critical**: Attempt to start audio engine and observe behavior
- [ ] Check Console.app for CoreAudio errors
- [ ] Test with middle device disconnected (check channel numbering)
- [ ] Test with input device disconnected (should fail validation)
- [ ] Test with all outputs disconnected (should not show in list)

### Risk Assessment

**Low Risk**:
- ✅ Filtering device list (worst case: shows broken devices)
- ✅ Adding logging (can be removed later)
- ✅ Skip missing devices in enumeration (fallback to old behavior if needed)

**Medium Risk**:
- ⚠️ CoreAudio may refuse to work with incomplete aggregate device
- ⚠️ Channel numbering might be wrong with gaps
- ⚠️ Clock source device might need to be present

**High Risk**:
- ❌ None - all changes are reversible

### Rollback Plan

If this doesn't work:
1. Set `missingDeviceStrategy = .throwError` to restore old behavior
2. Or remove the strategy entirely and revert `buildChannelMap()`

### Success Criteria

✅ **Minimum Success**:
- Aggregate devices with missing sub-devices don't crash the app
- Error messages are clearer about which devices are missing

✅ **Full Success**:
- Can select aggregate with missing devices
- Only connected outputs show in UI
- Audio engine works correctly with partial aggregate
- Channel routing is correct

---

## Implementation Order

1. ✅ Start with Phase 1 (Make inspector tolerant)
2. ✅ Then Phase 2 (Update UI filtering)
3. ✅ **STOP AND TEST** - This is the critical checkpoint
4. ❓ Phase 4 only if Phase 3 testing shows CoreAudio won't cooperate
5. 🎯 Iterate based on test results

**Estimated Time**:
- Implementation: 1-2 hours
- Testing: 30 minutes to 1 hour
- Debugging/iteration: Unknown (depends on CoreAudio behavior)

---

## Open Questions

1. **Will CoreAudio activate an aggregate device with missing sub-devices?**
   - Answer: Must test
   - Impact: Determines if Phase 4 is needed

2. **How does macOS handle channel numbers when a device is missing?**
   - Answer: Must test
   - Impact: May need channel offset adjustment logic

3. **Does the clock source device need to be present?**
   - Answer: Likely yes, but must test
   - Impact: May need special validation for clock source device

4. **Can we query CoreAudio for which sub-devices are actually active?**
   - Answer: Investigate `kAudioAggregateDevicePropertyActiveSubDeviceList` vs `kAudioAggregateDevicePropertyFullSubDeviceList`
   - Impact: Might give us better health check

---

## Notes

- This is a "try and see" approach - the critical unknowns require actual testing
- The implementation is designed to be incremental and reversible
- All changes maintain backward compatibility (old behavior via strategy enum)
- Heavy use of logging to understand what CoreAudio is doing
