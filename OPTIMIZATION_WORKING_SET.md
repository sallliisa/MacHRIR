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

### 3.2 [DONE] Error Types: Missing Localized Descriptions ⚠️ LOW IMPACT

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

### 3.3 [DONE] Magic Numbers ⚠️ LOW IMPACT

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
