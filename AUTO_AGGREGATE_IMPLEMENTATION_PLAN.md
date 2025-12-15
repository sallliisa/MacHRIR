# Auto-Aggregate Device Implementation Plan

## Research Summary

This implementation plan is based on comprehensive research of Apple's CoreAudio documentation, modern Swift implementations, and community best practices as of 2024-2025.

### Key Research Sources

1. **[CAAudioHardware Swift Library](https://github.com/sbooth/CAAudioHardware/blob/main/Sources/CAAudioHardware/AudioAggregateDevice.swift)** - Modern Swift wrapper (2024)
2. **[flyaga.info Technical Article](https://www.flyaga.info/creating-core-audio-aggregate-devices-programmatically/)** - Detailed implementation guide with critical workarounds
3. **[Stack Overflow Discussion](https://stackoverflow.com/questions/38810339/programmatically-create-aggregate-audio-devices-in-swift-using-coreaudio)** - Community implementations and pitfalls
4. **[GitHub Gist Example](https://gist.github.com/larussverris/5387819a3a7337937084730a86cee073)** - Objective-C reference implementation
5. **[Apple Developer Documentation](https://developer.apple.com/documentation/coreaudio)** - Official CoreAudio reference

---

## API Selection: AudioHardwareCreateAggregateDevice vs kAudioPlugInCreateAggregateDevice

### Research Findings

After examining current implementations, **both APIs are still functional in macOS 14-15 (2024-2025)**:

#### Method 1: AudioHardwareCreateAggregateDevice (Direct Function)
```swift
func AudioHardwareCreateAggregateDevice(
    _ inDescription: CFDictionary,
    _ outDeviceID: UnsafeMutablePointer<AudioDeviceID>
) -> OSStatus
```

**Pros:**
- ✅ Used by modern Swift libraries (CAAudioHardware, SimplyCoreAudio)
- ✅ Simpler API - returns device ID directly
- ✅ Single function call
- ✅ Well-documented in community resources

**Cons:**
- ⚠️ Marked as deprecated (but still functional)
- ⚠️ No official modern replacement from Apple

#### Method 2: kAudioPlugInCreateAggregateDevice (Property-Based)
```swift
var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioPlugInCreateAggregateDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectSetPropertyData(pluginObject, &propertyAddress, ...)
```

**Pros:**
- ✅ Uses modern property-based CoreAudio pattern
- ✅ Consistent with AudioObject API style

**Cons:**
- ⚠️ Requires additional step to get plugin object first
- ⚠️ Must query for created device by UID afterwards
- ⚠️ More complex implementation
- ⚠️ Less documented in modern resources

### Recommendation: Use AudioHardwareCreateAggregateDevice

**Rationale:**
1. **Current Usage**: Modern Swift libraries (2024-2025) use the direct function approach
2. **Simplicity**: Single function call vs. multi-step property approach
3. **Reliability**: Better documented in community resources
4. **Maintainability**: Easier to understand and debug
5. **Risk Mitigation**: Both APIs face same deprecation risk; choose simpler one

**Deprecation Strategy:**
- Implement with error handling that detects API removal
- Provide graceful fallback to manual aggregate mode
- Monitor macOS releases for API changes

---

## Critical Implementation Details from Research

### 1. Two-Stage Creation Pattern (CRITICAL!)

Research from [flyaga.info](https://www.flyaga.info/creating-core-audio-aggregate-devices-programmatically/) reveals:

> "The only way to reliably create an aggregate device is to create a blank device, and then manually set the sub-device list afterwards."

**Implementation Pattern:**
```swift
// Stage 1: Create blank device with only name and UID
let blankDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "MacHRIR Auto",
    kAudioAggregateDeviceUIDKey: "com.machrir.aggregate.auto",
    kAudioAggregateDeviceIsPrivateKey: 1
]

var deviceID: AudioDeviceID = 0
AudioHardwareCreateAggregateDevice(blankDescription as CFDictionary, &deviceID)

// CRITICAL: Allow system to process device creation
CFRunLoopRunInMode(.defaultMode, 0.1, false)

// Stage 2: Set sub-device list
// Use AudioObjectSetPropertyData with kAudioAggregateDevicePropertyFullSubDeviceList

// Stage 3: Set master device
// Use AudioObjectSetPropertyData with kAudioAggregateDevicePropertyMasterSubDevice
```

**Why This Matters:**
- Single-stage creation (with all properties at once) is unreliable
- Newly created device can temporarily disappear without run loop delays
- This is an undocumented requirement discovered through community experience

### 2. Required Configuration Keys

Based on research, these keys are essential:

```swift
// Initial creation (blank device)
kAudioAggregateDeviceNameKey: String          // Display name
kAudioAggregateDeviceUIDKey: String           // Unique identifier (reverse DNS)
kAudioAggregateDeviceIsPrivateKey: Int        // 1 = hidden from other apps

// Post-creation configuration (via AudioObjectSetPropertyData)
kAudioAggregateDevicePropertyFullSubDeviceList: [String]  // Array of device UIDs
kAudioAggregateDevicePropertyMasterSubDevice: String      // Clock master UID

// Per-subdevice configuration
kAudioSubDeviceUIDKey: String                 // Device UID
kAudioSubDeviceDriftCompensationKey: Bool     // Enable drift compensation (true)
```

### 3. Drift Compensation

From the [GitHub gist example](https://gist.github.com/larussverris/5387819a3a7337937084730a86cee073):

Each sub-device should have `kAudioSubDeviceDriftCompensationKey` set to `YES`/`true`. This enables macOS's built-in sample rate conversion for clock synchronization.

### 4. Device UID Requirements

All devices in CoreAudio are identified by UID (not AudioDeviceID). You must:
- Query each device's UID via `kAudioDevicePropertyDeviceUID`
- Pass UIDs (strings) to aggregate creation, not device IDs
- Query back the created device by UID

### 5. Cleanup and Orphaned Devices

Aggregate devices persist system-wide even after app termination. Implementation must:
- Use consistent UID pattern to identify app-created devices
- Clean up orphaned devices on launch
- Delete aggregate when user changes device selection
- Register cleanup handler for app termination

---

## Implementation Architecture

### Component Overview

```
MenuBarManager
    ↓
AggregateDeviceManager (NEW)
    ├── Creation/Destruction logic
    ├── Orphan cleanup
    ├── Device validation
    └── Clock master selection
    ↓
AudioGraphManager (Modified)
    └── Uses aggregate device
```

### New Class: AggregateDeviceManager

This class encapsulates all auto-aggregate logic:

```swift
class AggregateDeviceManager {
    // MARK: - Public API

    /// Create aggregate device from input/output pair
    func createAutoAggregate(
        input: AudioDevice,
        output: AudioDevice
    ) throws -> AudioDevice

    /// Destroy auto-created aggregate device
    func destroyAutoAggregate(_ device: AudioDevice) throws

    /// Check if device is MacHRIR auto-created aggregate
    func isAutoAggregate(_ device: AudioDevice) -> Bool

    /// Clean up orphaned aggregates from previous sessions
    func cleanupOrphanedAggregates() throws

    /// Validate devices can form compatible aggregate
    func validateCompatibility(
        input: AudioDevice,
        output: AudioDevice
    ) -> ValidationResult

    // MARK: - Private Implementation

    private func selectClockMaster(input: AudioDevice, output: AudioDevice) -> AudioDevice
    private func findCommonSampleRate(input: AudioDevice, output: AudioDevice) throws -> Double
    private func getDeviceUID(_ device: AudioDevice) throws -> String
    private func findDeviceByUID(_ uid: String) -> AudioDevice?
}

enum ValidationResult {
    case valid
    case invalid(reason: String)
}

enum AggregateError: Error {
    case apiUnavailable
    case creationFailed(OSStatus)
    case destructionFailed(OSStatus)
    case noCommonSampleRate
    case invalidDevice
    case deviceNotFound
    case missingUID
}
```

---

## Detailed Implementation Steps

### Phase 1: Core Creation Logic

#### Step 1.1: Device UID Resolution

```swift
private func getDeviceUID(_ device: AudioDevice) throws -> String {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var uid: CFString?
    var propertySize = UInt32(MemoryLayout<CFString?>.size)

    let status = AudioObjectGetPropertyData(
        device.id,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &uid
    )

    guard status == noErr, let uidString = uid as String? else {
        throw AggregateError.missingUID
    }

    return uidString
}
```

#### Step 1.2: Sample Rate Compatibility Check

```swift
private func findCommonSampleRate(
    input: AudioDevice,
    output: AudioDevice
) throws -> Double {
    // Query kAudioDevicePropertyAvailableNominalSampleRates for both devices
    let inputRates = try getAvailableSampleRates(device: input)
    let outputRates = try getAvailableSampleRates(device: output)

    // Find intersection
    let commonRates = Set(inputRates).intersection(Set(outputRates))

    guard !commonRates.isEmpty else {
        throw AggregateError.noCommonSampleRate
    }

    // Prefer 48000 Hz, then highest available
    if commonRates.contains(48000.0) {
        return 48000.0
    }
    return commonRates.max() ?? 44100.0
}

private func getAvailableSampleRates(device: AudioDevice) throws -> [Double] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0

    // Get size
    var status = AudioObjectGetPropertyDataSize(
        device.id,
        &propertyAddress,
        0,
        nil,
        &propertySize
    )

    guard status == noErr else {
        throw AggregateError.invalidDevice
    }

    let count = Int(propertySize) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)

    // Get data
    status = AudioObjectGetPropertyData(
        device.id,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &ranges
    )

    guard status == noErr else {
        throw AggregateError.invalidDevice
    }

    // Extract rates (typically min == max for discrete rates)
    return ranges.map { $0.mMinimum }
}
```

#### Step 1.3: Clock Master Selection

```swift
private func selectClockMaster(
    input: AudioDevice,
    output: AudioDevice
) -> AudioDevice {
    // Priority heuristic:

    // 1. Multi-channel device (likely the "real" audio source)
    if input.inputChannelCount > 2 && output.inputChannelCount <= 2 {
        return input
    }

    // 2. Hardware device over virtual device
    if input.isVirtualDevice && !output.isVirtualDevice {
        return output
    }
    if !input.isVirtualDevice && output.isVirtualDevice {
        return input
    }

    // 3. Device with highest sample rate capability
    let inputMaxRate = (try? getAvailableSampleRates(device: input).max()) ?? 0
    let outputMaxRate = (try? getAvailableSampleRates(device: output).max()) ?? 0

    if inputMaxRate > outputMaxRate {
        return input
    }

    // 4. Default to input device
    return input
}
```

#### Step 1.4: Two-Stage Aggregate Creation (CRITICAL!)

```swift
func createAutoAggregate(
    input: AudioDevice,
    output: AudioDevice
) throws -> AudioDevice {

    // Validate compatibility first
    let validation = validateCompatibility(input: input, output: output)
    guard case .valid = validation else {
        if case .invalid(let reason) = validation {
            throw AggregateError.invalidDevice // Should include reason
        }
        throw AggregateError.invalidDevice
    }

    // Get device UIDs
    let inputUID = try getDeviceUID(input)
    let outputUID = try getDeviceUID(output)

    // Generate unique UID for this aggregate
    let aggregateUID = "com.machrir.aggregate.\(inputUID.hashValue)-\(outputUID.hashValue)"

    // Stage 1: Create BLANK device (name and UID only)
    let blankDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "MacHRIR: \(input.name) → \(output.name)",
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceIsPrivateKey: 1  // Hide from other apps
    ]

    var deviceID: AudioDeviceID = 0
    var status = AudioHardwareCreateAggregateDevice(
        blankDescription as CFDictionary,
        &deviceID
    )

    guard status == noErr else {
        throw AggregateError.creationFailed(status)
    }

    // CRITICAL: Allow CoreAudio to process device creation
    CFRunLoopRunInMode(.defaultMode, 0.1, false)

    // Stage 2: Configure sub-device list
    try setSubDeviceList(
        deviceID: deviceID,
        subDeviceUIDs: [inputUID, outputUID]
    )

    // CRITICAL: Another run loop pause
    CFRunLoopRunInMode(.defaultMode, 0.1, false)

    // Stage 3: Set clock master
    let masterDevice = selectClockMaster(input: input, output: output)
    let masterUID = try getDeviceUID(masterDevice)
    try setClockMaster(deviceID: deviceID, masterUID: masterUID)

    // Final run loop pause
    CFRunLoopRunInMode(.defaultMode, 0.1, false)

    // Return aggregate device
    guard let aggregate = findDeviceByUID(aggregateUID) else {
        throw AggregateError.deviceNotFound
    }

    return aggregate
}

private func setSubDeviceList(
    deviceID: AudioDeviceID,
    subDeviceUIDs: [String]
) throws {

    // Build sub-device array with drift compensation
    var subDevices: [[String: Any]] = []
    for uid in subDeviceUIDs {
        subDevices.append([
            kAudioSubDeviceUIDKey: uid,
            kAudioSubDeviceDriftCompensationKey: true
        ])
    }

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var subDeviceArray = subDevices as CFArray
    let dataSize = UInt32(MemoryLayout<CFArray>.size)

    let status = AudioObjectSetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        dataSize,
        &subDeviceArray
    )

    guard status == noErr else {
        throw AggregateError.creationFailed(status)
    }
}

private func setClockMaster(
    deviceID: AudioDeviceID,
    masterUID: String
) throws {

    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyMasterSubDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var uidString = masterUID as CFString
    let dataSize = UInt32(MemoryLayout<CFString>.size)

    let status = AudioObjectSetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        dataSize,
        &uidString
    )

    guard status == noErr else {
        throw AggregateError.creationFailed(status)
    }
}
```

### Phase 2: Device Discovery and Cleanup

#### Step 2.1: Find Device by UID

```swift
private func findDeviceByUID(_ uid: String) -> AudioDevice? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0

    // Get device count
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize
    )

    guard status == noErr else { return nil }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    // Get device list
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &deviceIDs
    )

    guard status == noErr else { return nil }

    // Find device with matching UID
    for deviceID in deviceIDs {
        if let deviceUID = try? getDeviceUID(AudioDevice(id: deviceID)),
           deviceUID == uid {
            return AudioDevice(id: deviceID)
        }
    }

    return nil
}
```

#### Step 2.2: Identify Auto-Created Aggregates

```swift
func isAutoAggregate(_ device: AudioDevice) -> Bool {
    guard let uid = try? getDeviceUID(device) else {
        return false
    }

    // Check if UID matches our pattern
    return uid.hasPrefix("com.machrir.aggregate.")
}
```

#### Step 2.3: Orphan Cleanup

```swift
func cleanupOrphanedAggregates() throws {
    // Get all devices
    let allDevices = AudioDeviceManager.shared.allDevices

    // Find MacHRIR auto-aggregates
    let orphanedAggregates = allDevices.filter { isAutoAggregate($0) }

    // Destroy each one
    for aggregate in orphanedAggregates {
        try? destroyAutoAggregate(aggregate)
    }
}
```

#### Step 2.4: Device Destruction

```swift
func destroyAutoAggregate(_ device: AudioDevice) throws {
    // Verify it's actually an auto-aggregate
    guard isAutoAggregate(device) else {
        throw AggregateError.invalidDevice
    }

    let status = AudioHardwareDestroyAggregateDevice(device.id)

    guard status == noErr else {
        throw AggregateError.destructionFailed(status)
    }
}
```

### Phase 3: Device Validation

```swift
func validateCompatibility(
    input: AudioDevice,
    output: AudioDevice
) -> ValidationResult {

    // Check 1: Both devices must exist and be available
    guard input.isAlive, output.isAlive else {
        return .invalid(reason: "One or both devices are not available")
    }

    // Check 2: Input device must have input channels
    guard input.inputChannelCount > 0 else {
        return .invalid(reason: "\(input.name) has no input channels")
    }

    // Check 3: Output device must have output channels
    guard output.outputChannelCount >= 2 else {
        return .invalid(reason: "\(output.name) needs at least 2 output channels")
    }

    // Check 4: Must have common sample rate
    guard let _ = try? findCommonSampleRate(input: input, output: output) else {
        return .invalid(reason: "No common sample rate between devices")
    }

    // Check 5: Don't aggregate two aggregates (causes issues)
    if input.isAggregateDevice || output.isAggregateDevice {
        return .invalid(reason: "Cannot nest aggregate devices")
    }

    return .valid
}
```

### Phase 4: MenuBarManager Integration

#### Updated Menu Structure

```swift
class MenuBarManager {
    private let aggregateManager = AggregateDeviceManager()
    private var currentAutoAggregate: AudioDevice?

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Mode selector (future enhancement)
        // For now, always use auto-aggregate mode

        // Input device submenu
        let inputItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        inputItem.submenu = buildInputDeviceMenu()
        menu.addItem(inputItem)

        // Output device submenu
        let outputItem = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        outputItem.submenu = buildOutputDeviceMenu()
        menu.addItem(outputItem)

        // Status indicator
        if let aggregate = currentAutoAggregate {
            let statusItem = NSMenuItem(
                title: "Using: \(aggregate.name)",
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        // ... rest of menu (presets, controls, etc.)

        return menu
    }

    @objc func selectInputDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }

        selectedInput = device
        SettingsManager.shared.setInputDevice(device.id)

        // Auto-create aggregate if both devices selected
        if let output = selectedOutput {
            recreateAggregate(input: device, output: output)
        }

        rebuildMenu()
    }

    @objc func selectOutputDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }

        selectedOutput = device
        SettingsManager.shared.setOutputDevice(device.id)

        // Auto-create aggregate if both devices selected
        if let input = selectedInput {
            recreateAggregate(input: input, output: device)
        }

        rebuildMenu()
    }

    private func recreateAggregate(input: AudioDevice, output: AudioDevice) {
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }

        // Destroy old aggregate if exists
        if let oldAggregate = currentAutoAggregate {
            try? aggregateManager.destroyAutoAggregate(oldAggregate)
            currentAutoAggregate = nil
        }

        // Create new aggregate
        do {
            let aggregate = try aggregateManager.createAutoAggregate(
                input: input,
                output: output
            )
            currentAutoAggregate = aggregate

            // Configure audio manager to use aggregate
            try audioManager.setupAudioUnit(aggregateDevice: aggregate)

            // Restart audio if it was running
            if wasRunning {
                audioManager.start()
            }

        } catch AggregateError.noCommonSampleRate {
            showAlert(
                title: "Incompatible Devices",
                message: "\(input.name) and \(output.name) don't support the same sample rate."
            )
        } catch AggregateError.apiUnavailable {
            showAlert(
                title: "Feature Not Available",
                message: "Automatic device configuration is not available on this macOS version. Please create an aggregate device manually in Audio MIDI Setup."
            )
            // TODO: Switch to manual aggregate mode
        } catch {
            showAlert(
                title: "Device Configuration Failed",
                message: "Could not configure devices: \(error.localizedDescription)"
            )
        }
    }
}
```

### Phase 5: Application Lifecycle Integration

#### AppDelegate Updates

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarManager: MenuBarManager!
    private let aggregateManager = AggregateDeviceManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clean up orphaned aggregates from previous sessions
        do {
            try aggregateManager.cleanupOrphanedAggregates()
        } catch {
            print("Failed to clean up orphaned aggregates: \(error)")
        }

        // Initialize menu bar manager
        menuBarManager = MenuBarManager()

        // Register termination handler
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc func applicationWillTerminate(_ notification: Notification) {
        // Clean up auto-created aggregate
        if let aggregate = menuBarManager.currentAutoAggregate {
            try? aggregateManager.destroyAutoAggregate(aggregate)
        }
    }
}
```

---

## Testing Strategy

### Unit Tests

```swift
class AggregateDeviceManagerTests: XCTestCase {
    var manager: AggregateDeviceManager!

    override func setUp() {
        manager = AggregateDeviceManager()
    }

    func testDeviceUIDResolution() throws {
        let device = AudioDeviceManager.shared.defaultOutputDevice
        let uid = try manager.getDeviceUID(device)
        XCTAssertFalse(uid.isEmpty)
    }

    func testSampleRateCompatibility() throws {
        // Test with known compatible devices
    }

    func testAggregateCreationAndDestruction() throws {
        let input = // Select test input device
        let output = // Select test output device

        let aggregate = try manager.createAutoAggregate(input: input, output: output)
        XCTAssertTrue(manager.isAutoAggregate(aggregate))

        try manager.destroyAutoAggregate(aggregate)
        XCTAssertNil(manager.findDeviceByUID(aggregate.uid))
    }

    func testOrphanCleanup() throws {
        // Create aggregate, don't clean up
        // Call cleanupOrphanedAggregates()
        // Verify it's removed
    }

    func testIncompatibleDevices() {
        let result = manager.validateCompatibility(input: deviceA, output: deviceB)
        // Assert expected validation result
    }
}
```

### Manual Testing Checklist

#### Basic Functionality
- [ ] Select input device → no aggregate created (waiting for output)
- [ ] Select output device → aggregate created automatically
- [ ] Change input device → old aggregate destroyed, new one created
- [ ] Change output device → old aggregate destroyed, new one created
- [ ] Audio processes correctly through auto-aggregate
- [ ] HRIR convolution works with auto-aggregate
- [ ] Settings persist across app restart

#### Error Handling
- [ ] Incompatible devices (no common sample rate) → error message
- [ ] Select aggregate device as input → validation error
- [ ] Device disconnected while selected → graceful handling
- [ ] API failure → graceful fallback

#### Lifecycle
- [ ] Orphaned aggregates cleaned up on launch
- [ ] Aggregate destroyed on app quit
- [ ] Aggregate destroyed on device change
- [ ] No aggregate pollution in Audio MIDI Setup after testing

#### Stability
- [ ] 24-hour continuous operation (no clock drift!)
- [ ] No memory leaks
- [ ] CPU usage acceptable
- [ ] Multiple device switches don't cause issues
- [ ] Sleep/wake behavior correct

#### Edge Cases
- [ ] Same device selected for input and output
- [ ] Virtual devices (BlackHole, Loopback)
- [ ] USB audio devices
- [ ] Bluetooth devices (if supported)
- [ ] Built-in devices
- [ ] Multiple channel counts (2.0, 5.1, 7.1)

---

## Error Handling & User Communication

### Error Messages (User-Facing)

```swift
extension AggregateError {
    var userMessage: (title: String, message: String) {
        switch self {
        case .noCommonSampleRate:
            return (
                "Incompatible Devices",
                "The selected devices don't support the same sample rate. Try different devices or manually create an aggregate device in Audio MIDI Setup."
            )
        case .apiUnavailable, .creationFailed:
            return (
                "Auto-Configuration Failed",
                "MacHRIR couldn't automatically configure your devices. Please create an aggregate device manually in Audio MIDI Setup and select it from Advanced mode."
            )
        case .invalidDevice:
            return (
                "Invalid Device",
                "The selected device cannot be used. Make sure it has the required input or output channels."
            )
        case .deviceNotFound:
            return (
                "Device Not Found",
                "The aggregate device was created but couldn't be located. Please restart MacHRIR."
            )
        default:
            return (
                "Configuration Error",
                "An unexpected error occurred. Please try again or use manual aggregate mode."
            )
        }
    }
}
```

### Logging (Debug Only)

```swift
private func logDebug(_ message: String) {
    #if DEBUG
    NSLog("[AggregateManager] \(message)")
    #endif
}

// Usage in creation:
logDebug("Creating aggregate: \(inputUID) + \(outputUID)")
logDebug("Clock master selected: \(masterUID)")
logDebug("Aggregate created successfully: \(aggregateUID)")
```

---

## Performance Considerations

### Memory Impact
- Aggregate devices themselves: Minimal (~100KB per device)
- No additional memory overhead beyond current architecture
- Pre-existing circular buffer eliminated (savings: 65KB)

### CPU Impact
- Creation/destruction: One-time cost (~100-200ms)
- No runtime CPU overhead (clock sync done by OS)
- Expected CPU reduction vs. current implementation

### Latency
- Aggregate device latency: Typically 512-1024 samples
- OS handles buffering between sub-devices
- Expected latency reduction vs. current circular buffer approach

---

## Future Enhancements

### Phase 2: Mode Selection
Add UI to switch between auto-aggregate and manual aggregate modes:
```
Settings ▶
├── ○ Automatic (Create aggregate for me)
├── • Manual (I'll create my own aggregate)
```

### Phase 3: Custom Clock Master
Add advanced setting to override clock master selection:
```
Advanced ▶
├── Clock Master: ○ Auto  ○ Input  ○ Output
```

### Phase 4: Sample Rate Control
Add UI to force specific sample rate:
```
Advanced ▶
├── Sample Rate: ○ Auto  ○ 44100  ○ 48000  ○ 96000
```

### Phase 5: Aggregate Persistence Option
Allow user to choose whether aggregate is destroyed on quit:
```
Settings ▶
├── ☐ Keep aggregate device after quit
```

---

## Migration from Manual Aggregate Branch

### Current Branch State
Branch: `system_aggregate_device` (already uses aggregate architecture)

### Migration Steps

1. **Keep existing AudioGraphManager single-unit implementation** ✅
   - Already refactored to use single Audio Unit
   - No changes needed

2. **Add AggregateDeviceManager class**
   - New file: `AggregateDeviceManager.swift`
   - Implement all methods from this plan

3. **Update MenuBarManager**
   - Change from single aggregate selector to input/output selectors
   - Add aggregate recreation logic
   - Update settings persistence

4. **Update AudioDevice.swift**
   - Add `isAggregateDevice` property
   - Add `isVirtualDevice` property (for clock master heuristic)
   - Add `isAlive` property (for validation)

5. **Update AppDelegate**
   - Add orphan cleanup on launch
   - Add cleanup on termination

6. **Testing**
   - Extensive testing with Phase 5 checklist
   - Verify no clock drift over 24+ hours

---

## Risk Assessment & Mitigation

### Risk 1: API Removal (Medium Risk)
**Risk**: Apple removes `AudioHardwareCreateAggregateDevice` in future macOS.

**Impact**: Auto-aggregate feature breaks entirely.

**Mitigation**:
- Detect API availability at runtime
- Graceful fallback to manual aggregate mode
- Clear error message to users
- Keep manual aggregate code path maintained

**Likelihood**: Low-Medium (API still used in system tools)

### Risk 2: Device Compatibility Issues (High Risk)
**Risk**: Some device combinations don't work in aggregate mode.

**Impact**: Users can't use MacHRIR with their hardware.

**Mitigation**:
- Comprehensive validation before creation
- Clear error messages explaining why devices are incompatible
- Document known incompatible device combinations
- Provide troubleshooting guide
- Consider maintaining manual aggregate mode as fallback

**Likelihood**: Medium-High (USB audio devices can be problematic)

### Risk 3: Timing/Race Conditions (Medium Risk)
**Risk**: CoreAudio timing issues cause creation failures.

**Impact**: Intermittent failures creating aggregates.

**Mitigation**:
- Use run loop pauses as documented by community
- Retry logic with exponential backoff
- Extensive testing with various devices
- Log detailed error information for debugging

**Likelihood**: Low-Medium (mitigated by two-stage creation pattern)

### Risk 4: Orphaned Devices (Low Risk)
**Risk**: App crashes leave orphaned aggregate devices.

**Impact**: Audio MIDI Setup polluted with dead devices.

**Mitigation**:
- Cleanup on every launch
- Consistent UID pattern for identification
- User can manually delete in Audio MIDI Setup
- Minimal impact (cosmetic issue)

**Likelihood**: High (crashes happen), Severity: Low

### Risk 5: Performance Regression (Low Risk)
**Risk**: Aggregate device approach has higher CPU/latency.

**Impact**: Worse user experience than manual aggregate.

**Mitigation**:
- Extensive performance profiling before release
- Compare against manual aggregate (not dual-device)
- OS-level clock sync is typically efficient
- Monitor user feedback

**Likelihood**: Very Low (OS-level sync is efficient)

---

## Success Criteria

### Must Have (Release Blockers)
✅ No clock drift issues over 24+ hour operation
✅ Auto-aggregate creation works with common device combinations
✅ Graceful error handling for incompatible devices
✅ Orphan cleanup functions correctly
✅ Audio quality identical to manual aggregate approach
✅ No memory leaks
✅ CPU usage ≤ manual aggregate implementation

### Should Have (High Priority)
✅ Clear user-facing error messages
✅ Comprehensive validation before creation
✅ Settings persistence works correctly
✅ Device hot-plug handling
✅ Sleep/wake behavior correct

### Nice to Have (Future Enhancements)
⏳ Mode switcher (auto vs manual)
⏳ Custom clock master selection
⏳ Sample rate override
⏳ Aggregate persistence option

---

## Implementation Timeline

### Phase 1: Core Implementation (5-7 days)
- Implement `AggregateDeviceManager` class
- All creation/destruction methods
- Validation logic
- Device UID resolution
- Sample rate compatibility checking

### Phase 2: Integration (3-4 days)
- Update `MenuBarManager`
- Update `AppDelegate`
- Settings persistence
- Error handling UI

### Phase 3: Testing (5-7 days)
- Unit tests
- Manual testing checklist
- Device compatibility testing
- Stability testing (24hr runs)
- Performance profiling

### Phase 4: Polish & Documentation (2-3 days)
- User-facing error messages
- Debug logging
- Update CLAUDE.md
- User guide for troubleshooting

**Total Estimated Duration: 15-21 days**

---

## Conclusion

The auto-aggregate implementation builds on the existing aggregate device architecture (already implemented) and adds automatic device management for superior UX. By using the two-stage creation pattern discovered through community research, we can reliably create aggregate devices programmatically.

**Key Advantages:**
1. ✅ **Clock drift eliminated** (via aggregate device architecture - already done)
2. ✅ **Simple UX** (select two devices, not one aggregate)
3. ✅ **No user education needed** (no Audio MIDI Setup required)
4. ✅ **Automatic optimization** (smart clock master selection, sample rate selection)
5. ✅ **Clean lifecycle** (automatic cleanup, no device pollution)

**Key Risks:**
- API deprecation (mitigated by fallback mode)
- Device compatibility (mitigated by validation + error messages)
- Timing issues (mitigated by two-stage pattern + run loop pauses)

**Recommendation: Proceed with implementation.**

The research validates this approach as feasible and used successfully in modern macOS applications. The two-stage creation pattern is critical and well-documented in community resources.

---

## References

1. **[CAAudioHardware](https://github.com/sbooth/CAAudioHardware/blob/main/Sources/CAAudioHardware/AudioAggregateDevice.swift)** - Modern Swift implementation (2024)
2. **[flyaga.info](https://www.flyaga.info/creating-core-audio-aggregate-devices-programmatically/)** - Critical two-stage creation pattern
3. **[Stack Overflow](https://stackoverflow.com/questions/38810339/programmatically-create-aggregate-audio-devices-in-swift-using-coreaudio)** - Community discussion and examples
4. **[GitHub Gist](https://gist.github.com/larussverris/5387819a3a7337937084730a86cee073)** - Objective-C reference implementation
5. **[Apple CoreAudio Documentation](https://developer.apple.com/documentation/coreaudio)** - Official API reference

---

*Document Version: 1.0*
*Last Updated: 2025-11-23*
*Author: Research-based implementation plan*
*Branch: system_aggregate_device*
