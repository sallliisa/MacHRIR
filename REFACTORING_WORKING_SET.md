### 🟡 Issue 6: Two Listeners for Overlapping Events

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
