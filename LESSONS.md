# Lessons Learned: Dynamic Audio Device Reconnection

## The Problem

When a physical audio device (e.g., Bluetooth headphones) that is part of an aggregate device is disconnected and then reconnected:

1. ✅ The UI would not update to show the reconnected device
2. ✅ Channel indexing would become incorrect when topology changed
3. ✅ The app would not automatically restore the previously-selected device
4. ✅ Manual device selection would fail - audio would "stick" to the reconnected device

## Root Causes Discovered

### 1. **CoreAudio Assigns New Device IDs on Reconnection** 🔑

**Discovery:** When you disconnect and reconnect a device, CoreAudio assigns it a completely new `AudioDeviceID`.

**Evidence from logs:**

```
Before disconnect: Device ID = 111 (headphones)
After reconnect:  Device ID = 144 (same headphones!)
```

**Lesson:** Never use device IDs as stable identifiers across disconnection/reconnection cycles. Use device **names** instead.

**Fix:** Changed from `lastUserSelectedOutputID: AudioDeviceID?` to `lastUserSelectedOutputName: String?`

---

### 2. **Two Different Listeners Fire at Different Times**

**Discovery:** When a sub-device reconnects to an aggregate, TWO separate CoreAudio listeners fire in sequence:

1. **Aggregate Configuration Change** - Fires immediately when sub-device list changes

   - Listener: `kAudioAggregateDevicePropertyFullSubDeviceList`
   - Problem: Fires BEFORE the device is actually available
   - Evidence: `availableOutputs` only showed fallback device, not reconnected device

2. **System Device Change** - Fires when device is actually enumerable
   - Publisher: `AudioDeviceManager.$aggregateDevices`
   - Timing: Fires ~100ms later when device is fully available
   - Evidence: This is when `availableOutputs.count` changed from 1 → 2

**Lesson:** For device restoration after reconnection, use the **system device change** listener, not the aggregate configuration change listener.

**Fix:** Implemented restoration logic in both paths, but only the system device change path succeeds because the device is actually available.

---

### 3. **`setOutputChannels()` vs `setupAudioUnit()` After Reconnection**

**Discovery:** After a device reconnects with a new ID, calling `setOutputChannels()` alone doesn't work.

**Why:** The audio unit internally holds references to device IDs. When you call `setOutputChannels()`, it updates the channel range but still points to the OLD device ID (which no longer exists).

**Evidence:** After reconnection, manual device switching would fail - audio remained "stuck" on the reconnected device regardless of UI selection.

**Lesson:** When restoring a device after reconnection (where the device ID changed), you must:

1. Stop the audio engine
2. Call `setupAudioUnit()` to reinitialize with the NEW device ID
3. Restart the audio engine

**Don't:** Just call `setOutputChannels()` - this only works when the underlying device hasn't changed

**Do:** Reinitialize the audio unit completely when the device ID changes

---

### 4. **Virtual Loopback Devices Are Input-Only**

**Discovery:** Devices like BlackHole and Soundflower are virtual loopback devices used for routing, not actual output targets.

**Problem:** They would appear in the output device menu, confusing users.

**Lesson:** Filter out virtual loopback devices from output device lists by checking device names.

**Fix:**

```swift
availableOutputs = allOutputs.filter { output in
    let name = output.name.lowercased()
    return !name.contains("blackhole") && !name.contains("soundflower")
}
```

---

## Implementation Pattern

### Correct Device Restoration Flow

```swift
// 1. Track by NAME, not ID
private var lastUserSelectedOutputName: String?

// 2. When user selects a device
func selectOutputDevice(_ output: SubDeviceInfo) {
    selectedOutputDevice = output
    lastUserSelectedOutputName = output.name  // Store name, not ID
    // ... setup audio
}

// 3. When device reconnects (system device change fires)
func refreshAvailableOutputsIfNeeded() {
    // Find device by NAME
    if let userName = lastUserSelectedOutputName,
       let original = availableOutputs.first(where: { $0.name == userName }) {

        // Important: Device ID changed, must reinitialize
        if selectedOutputDevice?.name != userName {
            let wasRunning = audioManager.isRunning
            if wasRunning { audioManager.stop() }

            try audioManager.setupAudioUnit(  // Not setOutputChannels!
                aggregateDevice: aggregate,
                outputChannelRange: original.startChannel..<(original.startChannel + 2)
            )

            if wasRunning { audioManager.start() }
        }
    }
}
```

---

## Debugging Techniques That Worked

### 1. **Console Logging with Device IDs**

```swift
print("[MenuBarManager] DEBUG: lastUserSelectedOutputID = \(lastUserSelectedOutputID)")
print("[MenuBarManager] DEBUG: availableOutputs IDs = \(availableOutputs.map { $0.device.id })")
```

This revealed that device IDs change on reconnection.

### 2. **Tracking All Listener Firings**

Adding logs to both `handleAggregateConfigurationChange()` and `refreshAvailableOutputsIfNeeded()` revealed the timing and order of events.

### 3. **Asking User for Sequential Logs**

Requesting step-by-step console output (disconnect → reconnect → manual switch) revealed the exact sequence of events and which code paths weren't executing.

---

## Best Practices for CoreAudio Device Management

1. ✅ **Use device names for stable identification across reconnections**
2. ✅ **Implement both aggregate and system-level device change listeners**
3. ✅ **Reinitialize audio units when device IDs change (don't just update channels)**
4. ✅ **Filter out virtual loopback devices from user-facing menus**
5. ✅ **Track user's original selection separately from automatic fallbacks**
6. ✅ **Stop/restart audio when reinitializing - don't assume hot-swap works**
7. ✅ **Add comprehensive diagnostic logging during development**

---

## What Didn't Work (False Starts)

1. ❌ Tracking by device ID → IDs change on reconnection
2. ❌ Using `setOutputChannels()` after reconnection → Doesn't update device reference
3. ❌ Relying only on aggregate config change listener → Fires before device is available
4. ❌ Assuming UI updates automatically → Manual `updateMenu()` calls required
5. ❌ Trying to avoid audio restart during restoration → Necessary for device ID changes

---

## Performance Considerations

- Device reconnection causes brief audio interruption (stop → reinit → start)
- This is acceptable because the device was physically disconnected anyway
- Users expect a brief pause when reconnecting Bluetooth devices
- The ~100ms delay between listeners is imperceptible to users

---

## Future Improvements

- [ ] Add user notification when device reconnects and restores
- [ ] Consider debouncing rapid connect/disconnect events
- [ ] Monitor `kAudioAggregateDevicePropertyActiveSubDeviceList` in addition to `FullSubDeviceList`
- [ ] Handle edge case where device name changes (unlikely but possible with firmware updates)
- [ ] Add telemetry to track how often devices reconnect in production

---

**Date:** 2025-11-24  
**Component:** MenuBarManager, AudioDeviceManager  
**Impact:** Critical - Affects all users with Bluetooth/USB devices
