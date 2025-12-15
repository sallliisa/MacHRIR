# Aggregate Device Architecture Migration Plan

## Executive Summary

This document outlines the migration from MacHRIR's current dual-device architecture (separate input/output Audio Units with clock drift management) to a simplified aggregate device architecture where macOS CoreAudio handles clock synchronization.

**Primary Goal**: Eliminate clock drift issues by using macOS aggregate devices instead of managing separate device clocks in application code.

**Key Benefit**: Eliminate buffer overflow/underflow after ~2 hours of continuous operation while significantly simplifying the codebase.

**Key Tradeoff**: Users must pre-configure aggregate devices via Audio MIDI Setup instead of selecting arbitrary input/output device pairs from the menu.

---

## Current Architecture Analysis

### Current Audio Flow
```
Input Device → Input Audio Unit (HAL) → Input Callback → Circular Buffer (65KB)
                                                              ↓ (Clock Domain Crossing)
Output Callback ← Output Audio Unit (HAL) ← Output Device ← HRIR Convolution
```

### Current Components & Responsibilities

| Component | Current Role | Issues |
|-----------|--------------|---------|
| `AudioGraphManager.swift` | Manages two separate `AudioUnit` instances | Complex dual-unit lifecycle management |
| `CircularBuffer.swift` | Thread-safe ring buffer with NSLock | Clock drift accumulation, lock contention |
| Input Callback | Reads from input device, writes to buffer | Runs on input device clock |
| Output Callback | Reads from buffer, applies convolution, outputs | Runs on output device clock, handles drift |
| `MenuBarManager.swift` | Separate input/output device selection menus | User can select incompatible device pairs |

### Problems with Current Architecture

1. **Clock Drift**: Independent device clocks drift ~0.01% → ~1 buffer overrun per 2 hours
2. **Complexity**: Two audio units, two callbacks, thread synchronization, buffer management
3. **Performance Overhead**: NSLock contention, buffer copies, drift correction logic
4. **Reliability**: Buffer exhaustion causes complete audio failure
5. **Latency**: 65KB buffer adds unnecessary latency (~340ms @ 48kHz stereo)

---

## Target Architecture

### New Audio Flow
```
Aggregate Device (Input Channels) → Single Audio Unit (HAL) → Single Callback
                                                                    ↓
                                                            HRIR Convolution
                                                                    ↓
                                        Single Callback → Aggregate Device (Output Channels)
```

### Single-Callback Pass-Through Model

All processing happens in one render callback:
1. Callback receives `AudioBufferList` with input channels already populated by CoreAudio
2. Process input through HRIR convolution → stereo output
3. Write stereo output to output channels in the same `AudioBufferList`
4. Return from callback

**Key Insight**: No circular buffer needed because input and output operate on the same clock (aggregate device's master clock).

### Component Changes Overview

| Component | New Role | Changes Required |
|-----------|----------|------------------|
| `AudioGraphManager.swift` | Manages single `AudioUnit` for aggregate device | Major refactor: remove dual units, remove input callback, simplify lifecycle |
| `CircularBuffer.swift` | **REMOVED** | Delete entire file |
| Render Callback | Pass-through processing: read input, convolve, write output | Combine both callback responsibilities |
| `MenuBarManager.swift` | Aggregate device selection only | Replace input/output menus with single aggregate device menu |
| `AudioDevice.swift` | Filter for aggregate devices only | Add aggregate device detection logic |
| `SettingsManager.swift` | Store single device ID | Remove separate input/output device settings |

---

## Detailed Technical Changes

### Phase 1: AudioGraphManager Refactor

#### Current Structure
```swift
class AudioGraphManager {
    private var inputAudioUnit: AudioUnit?
    private var outputAudioUnit: AudioUnit?
    private var circularBuffer: CircularBuffer

    func setupInputUnit()
    func setupOutputUnit()
    func inputRenderCallback() -> OSStatus
    func renderCallback() -> OSStatus
}
```

#### Target Structure
```swift
class AudioGraphManager {
    private var audioUnit: AudioUnit?  // Single unit
    // Remove: inputAudioUnit, outputAudioUnit, circularBuffer

    func setupAudioUnit(aggregateDevice: AudioDevice)
    func renderCallback() -> OSStatus  // Single callback
}
```

#### Key Implementation Changes

**1. Audio Unit Configuration**
```swift
// Current: Two units with different element configurations
// - Input unit: Enable I/O on element 1, disable element 0
// - Output unit: Default element 0 configuration

// Target: Single unit with default I/O configuration
// Element 0: Output (to aggregate device output channels)
// Element 1: Input (from aggregate device input channels)
// Both elements enabled (kAudioOutputUnitProperty_EnableIO)
```

**2. Stream Format Configuration**
```swift
// Current: Set formats separately for each unit

// Target: Set format once for aggregate device
// - Input scope of element 1: Matches aggregate input channel count
// - Output scope of element 0: Stereo (2 channels for HRIR output)
// - Sample rate: Must match aggregate device's sample rate
```

**3. Single Render Callback**
```swift
// Callback signature (AURenderCallback)
func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderCallbackStruct>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus

// Implementation steps:
// 1. Allocate input AudioBufferList (for element 1)
// 2. Call AudioUnitRender() to pull input from element 1
// 3. Process input through HRIR convolution
// 4. Write stereo output to ioData (element 0 output buffers)
// 5. Return noErr
```

**4. Buffer Pre-Allocation Strategy**
```swift
// Pre-allocate in init():
private var inputBufferList: UnsafeMutablePointer<AudioBufferList>
private var inputChannelBuffers: [UnsafeMutablePointer<Float>]  // One per input channel

// In callback:
// - Use pre-allocated inputBufferList for AudioUnitRender()
// - Zero malloc policy maintained
```

#### Removed Code
- `setupInputUnit()` method
- `setupOutputUnit()` method
- `inputRenderCallback()` method
- All circular buffer read/write calls
- Clock drift detection/correction logic
- Input/output buffer size mismatch handling

---

### Phase 2: Remove CircularBuffer

**Action**: Delete `CircularBuffer.swift` entirely.

**Impact Analysis**:
- Only referenced by `AudioGraphManager`
- No other components depend on it
- 65KB memory freed per instance

**Validation**: Build project after removal should have zero references to `CircularBuffer`.

---

### Phase 3: AudioDevice.swift Enhancements

#### Add Aggregate Device Detection

```swift
extension AudioDevice {
    var isAggregateDevice: Bool {
        var deviceUID: CFString?
        var propertySize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            id,
            &AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            0,
            nil,
            &propertySize,
            &deviceUID
        )

        // Aggregate devices have UIDs like "com.apple.audio.aggregate.XXX"
        if status == noErr, let uid = deviceUID as String? {
            return uid.contains("aggregate")
        }
        return false
    }

    // Get the physical devices that make up this aggregate
    var aggregateSubDevices: [AudioDeviceID]? {
        // Query kAudioAggregateDevicePropertyActiveSubDeviceList
        // Return array of sub-device IDs
    }
}
```

#### Filter Device Lists

```swift
class AudioDeviceManager {
    // Old:
    var inputDevices: [AudioDevice]
    var outputDevices: [AudioDevice]

    // New:
    var aggregateDevices: [AudioDevice] {
        return allDevices.filter { $0.isAggregateDevice }
    }
}
```

---

### Phase 4: MenuBarManager UI Changes

#### Current Menu Structure
```
MacHRIR
├── Input Device ▶
│   ├── • Device 1
│   ├── ○ Device 2
│   └── ○ Device 3
├── Output Device ▶
│   ├── ○ Device 1
│   └── • Device 2
├── HRIR Presets ▶
├── ☑ Enable Convolution
├── Start/Stop
```

#### New Menu Structure
```
MacHRIR
├── Aggregate Device ▶
│   ├── • MyAggregateDevice
│   ├── ○ AnotherAggregate
│   └── [No aggregate device found - Create one]
├── HRIR Presets ▶
├── ☑ Enable Convolution
├── Start/Stop
├── ──────────
├── Help: Creating Aggregate Devices
```

#### Implementation Changes

**1. Replace Device Selection Methods**
```swift
// Remove:
@objc func selectInputDevice(_ sender: NSMenuItem)
@objc func selectOutputDevice(_ sender: NSMenuItem)

// Add:
@objc func selectAggregateDevice(_ sender: NSMenuItem)
```

**2. Add Help/Guidance Menu Item**
```swift
@objc func showAggregateDeviceHelp(_ sender: NSMenuItem) {
    // Open system Audio MIDI Setup.app
    // Or show instructions dialog
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
}
```

**3. Validation Logic**
```swift
private func validateAggregateDevice(_ device: AudioDevice) -> Bool {
    // Check that device has both input and output channels
    guard device.inputChannelCount > 0 else { return false }
    guard device.outputChannelCount >= 2 else { return false }  // Need stereo output

    // Optional: Check sample rate compatibility
    // Optional: Check sub-device status

    return true
}
```

**4. Empty State Handling**
```swift
private func buildAggregateDeviceMenu() -> NSMenu {
    let menu = NSMenu()
    let devices = deviceManager.aggregateDevices

    if devices.isEmpty {
        let item = NSMenuItem(
            title: "No aggregate devices found",
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        menu.addItem(item)

        menu.addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(
            title: "Create Aggregate Device...",
            action: #selector(showAggregateDeviceHelp(_:)),
            keyEquivalent: ""
        )
        helpItem.target = self
        menu.addItem(helpItem)
    } else {
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectAggregateDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device
            item.state = (device.id == audioManager.aggregateDevice?.id) ? .on : .off
            item.isEnabled = validateAggregateDevice(device)
            menu.addItem(item)
        }
    }

    return menu
}
```

---

### Phase 5: SettingsManager Changes

#### Current Settings Schema
```swift
enum SettingsKey {
    static let inputDeviceID = "inputDeviceID"
    static let outputDeviceID = "outputDeviceID"
    static let selectedPresetName = "selectedPresetName"
    static let convolutionEnabled = "convolutionEnabled"
}
```

#### New Settings Schema
```swift
enum SettingsKey {
    static let aggregateDeviceID = "aggregateDeviceID"  // Replaces input/output
    static let selectedPresetName = "selectedPresetName"  // Unchanged
    static let convolutionEnabled = "convolutionEnabled"  // Unchanged
}
```

#### Migration Logic
```swift
func migrateSettings() {
    // One-time migration for existing users
    if UserDefaults.standard.object(forKey: "inputDeviceID") != nil {
        // Clear old settings
        UserDefaults.standard.removeObject(forKey: "inputDeviceID")
        UserDefaults.standard.removeObject(forKey: "outputDeviceID")

        // Don't migrate device ID (incompatible format)
        // User will need to select aggregate device manually
    }
}
```

---

## Channel Mapping Considerations

### Current Behavior
- Input channels: Determined by input device (e.g., 8 channels for 7.1 input)
- Output channels: Always 2 (stereo HRIR output to output device)

### New Behavior with Aggregate Devices

Aggregate devices present **all channels** from all sub-devices:

**Example**: Aggregate device with 8-channel input device + stereo output device
- Total channels visible to Audio Unit: 10 channels
- Channels 0-7: Input device channels
- Channels 8-9: Output device channels

#### Implementation Strategy

**Option 1: User-Configured Channel Mapping** (Recommended)
- User configures aggregate device in Audio MIDI Setup to have:
  - Input channels from multi-channel device
  - Output channels from stereo device
- MacHRIR reads `kAudioDevicePropertyStreamConfiguration` to determine channel layout
- Assumes first N channels are input, last 2 are output

**Option 2: Manual Channel Offset Configuration**
- Add UI for user to specify which channels are input vs output
- More flexible but adds complexity

**Recommended**: Option 1 with validation that warns users if configuration looks incorrect.

---

## Migration Phases & Timeline

### Phase 0: Preparation & Branch Setup
**Duration**: 1 day

- [x] Create `system_aggregate_device` branch (already exists)
- [ ] Document current behavior with test cases
- [ ] Create backup build of current working version
- [ ] Set up test aggregate devices for development

### Phase 1: Core Audio Engine Refactor
**Duration**: 3-5 days

**Tasks**:
1. [ ] Refactor `AudioGraphManager` to single audio unit
2. [ ] Implement single render callback with pass-through processing
3. [ ] Remove all circular buffer dependencies
4. [ ] Pre-allocate input buffers for new callback
5. [ ] Test basic audio pass-through (no convolution)
6. [ ] Test with convolution enabled
7. [ ] Verify zero malloc in callbacks with Instruments

**Success Criteria**:
- Audio passes through aggregate device without dropouts
- HRIR convolution works correctly
- No memory allocations in render callback
- CPU usage ≤ current implementation

### Phase 2: Device Management Changes
**Duration**: 2-3 days

**Tasks**:
1. [ ] Add aggregate device detection to `AudioDevice.swift`
2. [ ] Implement `AudioDeviceManager.aggregateDevices` filtering
3. [ ] Add aggregate device validation logic
4. [ ] Update device change notifications to handle single device
5. [ ] Test device hot-plugging behavior

**Success Criteria**:
- All system aggregate devices detected correctly
- Invalid aggregate devices rejected with clear reason
- Device disconnection handled gracefully

### Phase 3: UI/UX Updates
**Duration**: 2-3 days

**Tasks**:
1. [ ] Update `MenuBarManager` to single device menu
2. [ ] Implement aggregate device help menu item
3. [ ] Add empty state handling (no aggregate devices)
4. [ ] Update status bar tooltips/info
5. [ ] Update about/help text

**Success Criteria**:
- Users can select aggregate devices from menu
- Clear guidance when no aggregate devices exist
- Device selection persists across app restarts

### Phase 4: Settings & Persistence
**Duration**: 1 day

**Tasks**:
1. [ ] Update `SettingsManager` schema
2. [ ] Implement settings migration logic
3. [ ] Test settings persistence across launches
4. [ ] Handle edge case: saved device no longer exists

**Success Criteria**:
- Settings migration works for existing users
- New settings schema persists correctly

### Phase 5: Testing & Validation
**Duration**: 3-5 days

**Tasks**:
1. [ ] Extended stability testing (8+ hour runs)
2. [ ] Test with various aggregate device configurations
3. [ ] Test all HRIR presets with different channel counts
4. [ ] Profile with Instruments (CPU, Memory, Allocations)
5. [ ] Test sleep/wake behavior
6. [ ] Test device disconnect/reconnect scenarios
7. [ ] Validate Console.app logs for errors

**Success Criteria**:
- No audio dropouts over 8+ hour test
- No clock drift issues
- All HRIR presets work correctly
- CPU usage ≤ current implementation
- Memory usage stable over time

### Phase 6: Documentation & Release
**Duration**: 1-2 days

**Tasks**:
1. [ ] Update `CLAUDE.md` with new architecture
2. [ ] Create user guide for aggregate device setup
3. [ ] Update README with aggregate device requirements
4. [ ] Write release notes explaining breaking changes
5. [ ] Create migration guide for existing users

**Success Criteria**:
- Complete documentation of new architecture
- Clear user-facing migration instructions

**Total Estimated Duration**: 12-19 days

---

## Testing Strategy

### Unit Tests (If Framework Exists)

```swift
class AudioGraphManagerTests: XCTestCase {
    func testSingleAudioUnitCreation()
    func testAggregateDeviceConfiguration()
    func testRenderCallbackWithoutConvolution()
    func testRenderCallbackWithConvolution()
    func testChannelCountMismatch()
    func testSampleRateConfiguration()
}

class AudioDeviceTests: XCTestCase {
    func testAggregateDeviceDetection()
    func testAggregateDeviceValidation()
    func testSubDeviceEnumeration()
}
```

### Manual Testing Checklist

#### Basic Functionality
- [ ] App launches and menu bar icon appears
- [ ] Aggregate devices listed in menu
- [ ] Can select aggregate device
- [ ] Audio starts without errors
- [ ] Audio passes through without convolution
- [ ] Audio processes with convolution enabled
- [ ] Can switch HRIR presets while running
- [ ] Can stop/start audio stream
- [ ] Device selection persists after quit/relaunch

#### Stability Tests
- [ ] 2 hour continuous playback (previous failure point)
- [ ] 8 hour continuous playback
- [ ] 24 hour continuous playback
- [ ] No buffer overrun/underrun errors in Console.app
- [ ] Stable memory usage over time

#### Edge Cases
- [ ] Aggregate device disconnected while audio running
- [ ] Sub-device of aggregate disconnected
- [ ] Sample rate change on aggregate device
- [ ] Mac wakes from sleep while audio running
- [ ] Mac goes to sleep while audio running
- [ ] Switch to different aggregate device while running
- [ ] No aggregate devices available (empty state)
- [ ] Aggregate device with mismatched sample rates
- [ ] Aggregate device with only input channels (no output)
- [ ] Aggregate device with only output channels (no input)

#### Performance Tests
- [ ] CPU usage profile with Instruments
- [ ] Memory allocations profile (verify zero in callbacks)
- [ ] Thread usage analysis
- [ ] Latency measurements (should be lower than current)
- [ ] Compare CPU vs. current dual-unit implementation

#### HRIR Processing Tests
- [ ] Test all channel count configurations (2.0, 5.1, 7.1, 7.1.4)
- [ ] Test with various HRIR presets
- [ ] Verify multi-channel accumulation works correctly
- [ ] Test sample rate conversion if needed
- [ ] Verify channel mapping correctness

---

## Rollback Plan

### Triggers for Rollback
- Audio dropouts or glitches not present in current version
- Higher CPU usage than current implementation
- Critical bugs discovered during Phase 5 testing
- Aggregate device approach fundamentally incompatible with use case

### Rollback Procedure
1. Revert `system_aggregate_device` branch to last stable commit on main
2. Re-release current stable version
3. Document issues encountered
4. Re-evaluate architectural approach

### Risk Mitigation
- Keep current main branch stable and deployable
- Tag last stable commit before merge
- Consider feature flag to toggle between architectures (advanced)

---

## User Communication & Migration

### Breaking Changes Notice

**For Existing Users**:
- App will no longer support selecting separate input/output devices
- Users must create aggregate devices in Audio MIDI Setup.app
- Previous device selections will not be migrated

### User-Facing Documentation

#### Quick Start Guide: Creating Aggregate Devices

```markdown
# Creating an Aggregate Device for MacHRIR

MacHRIR now requires an aggregate device to prevent audio drift issues.

## Steps:

1. Open **Audio MIDI Setup** (in /Applications/Utilities/)
2. Click **+** (bottom-left) → **Create Aggregate Device**
3. Name it (e.g., "MacHRIR Aggregate")
4. Check your input device (e.g., "BlackHole 2ch")
5. Check your output device (e.g., "MacBook Pro Speakers")
6. Set the input device as **Clock Source** (use dropdown on right)
7. Close Audio MIDI Setup
8. Launch MacHRIR and select your aggregate device

## Tips:
- Sample rates must match between devices
- Input device should be clock master (typically the multi-channel source)
- Some devices may not work well in aggregate mode (USB audio can be finicky)
```

#### In-App Help Text

When user clicks "Create Aggregate Device..." menu item:
- Open Audio MIDI Setup.app automatically
- Show alert with brief instructions
- Link to detailed online documentation

---

## Technical Risks & Mitigations

### Risk 1: Aggregate Device Reliability
**Risk**: Aggregate devices may introduce their own stability issues or not work with certain device combinations.

**Mitigation**:
- Extensive testing with various device combinations
- Document known incompatibilities
- Provide troubleshooting guide for common issues
- Consider allowing "advanced mode" to revert to dual-device architecture (future work)

### Risk 2: User Adoption Barrier
**Risk**: Users may find aggregate device setup too technical, leading to complaints or app abandonment.

**Mitigation**:
- Comprehensive documentation with screenshots
- In-app guidance and help links
- Consider auto-creating aggregate device programmatically (advanced, requires private APIs)
- Video tutorial on website

### Risk 3: Channel Mapping Complexity
**Risk**: Aggregate devices may present channels in unexpected order, breaking HRIR processing.

**Mitigation**:
- Clear validation and error messages
- Allow users to test audio pass-through before enabling convolution
- Consider adding channel mapping UI (future enhancement)
- Document recommended aggregate device configurations

### Risk 4: macOS Version Compatibility
**Risk**: Aggregate device behavior may vary across macOS versions.

**Mitigation**:
- Test on multiple macOS versions (12.0+)
- Document any version-specific issues
- Add runtime checks for problematic configurations

### Risk 5: Performance Regression
**Risk**: New architecture may introduce unexpected performance issues.

**Mitigation**:
- Extensive profiling with Instruments before release
- Compare metrics against current implementation
- Set hard performance criteria for Phase 5 approval

---

## Success Metrics

### Primary Success Criteria
✅ **Clock Drift Eliminated**: No audio dropouts after 24+ hours continuous operation

### Secondary Success Criteria
✅ **Simplified Codebase**: Remove CircularBuffer.swift (~300 lines), simplify AudioGraphManager (~200 lines removed)

✅ **Performance Maintained or Improved**:
- CPU usage ≤ current implementation
- Memory usage reduced (no 65KB buffer)
- Latency reduced (no buffering delay)

✅ **Zero Regressions**:
- All HRIR presets work correctly
- All channel configurations supported
- Audio quality identical to current implementation

### User Experience Criteria
✅ **Documentation Complete**: User guide, migration guide, troubleshooting guide published

✅ **Setup Time Acceptable**: Users can create aggregate device in <5 minutes with documentation

---

## Post-Migration Opportunities

Once aggregate device architecture is stable, consider:

### 1. Auto-Create Aggregate Devices
Research programmatic aggregate device creation to reduce user friction.

### 2. Advanced Channel Mapping UI
Allow users to manually map input channels to virtual speakers for complex setups.

### 3. Profile-Based Configuration
Save multiple aggregate device configurations and switch between them.

### 4. Enhanced Device Monitoring
Monitor aggregate device sub-device status and warn users of configuration issues.

### 5. Integration with Audio MIDI Setup
Deep-link directly to editing the selected aggregate device.

---

## References & Related Documents

- `CLAUDE.md` - Current architecture documentation
- `CPP_MIGRATION_PLAN.md` - C++ migration plans (still relevant for ConvolutionEngine)
- Apple CoreAudio Documentation: [Audio Unit Hosting Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/Introduction/Introduction.html)
- [Creating Aggregate Devices - Apple Support](https://support.apple.com/guide/audio-midi-setup/welcome/mac)

---

## Conclusion

The aggregate device migration represents a **fundamental architectural simplification** that solves the clock drift problem at its root rather than attempting to work around it. While it introduces a user setup step, the benefits in reliability, performance, and code maintainability far outweigh this tradeoff.

The migration is well-scoped, testable, and reversible. With proper execution of the phased plan, MacHRIR will emerge as a more robust and maintainable application.

**Recommendation**: Proceed with migration.

---

*Document Version: 1.0*
*Last Updated: 2025-11-23*
*Branch: system_aggregate_device*
