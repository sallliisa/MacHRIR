# Fix: Audio Engine Not Restarting After Device Disconnect

## Problem
When the active output device disconnects, audio engine stops but never restarts on fallback device.

## Root Cause
`handleOutputDeviceDisconnected()` method (line 842) stops audio but forgets to restart it.

## Fix Location
**File**: `MacHRIR/MenuBarManager.swift`
**Method**: `handleOutputDeviceDisconnected()` (lines 842-869)

## What to Change

### Add (before line 846):
```swift
let wasRunning = audioManager.isRunning
```

### Add (after line 860, inside the do block):
```swift
// Restart if was running before disconnect
if wasRunning {
    audioManager.start()
    print("[MenuBarManager] ✅ Audio engine restarted on fallback device")
}
```

## Complete Method Should Look Like:
```swift
private func handleOutputDeviceDisconnected() {
    print("[MenuBarManager] Currently-selected output was disconnected")

    // Capture running state BEFORE stopping
    let wasRunning = audioManager.isRunning

    if wasRunning {
        audioManager.stop()
    }

    if let firstAvailable = availableOutputs.first {
        selectedOutputDevice = firstAvailable

        do {
            if let aggregate = audioManager.aggregateDevice {
                try audioManager.setupAudioUnit(
                    aggregateDevice: aggregate,
                    outputChannelRange: firstAvailable.startChannel..<(firstAvailable.startChannel + 2)
                )
                print("[MenuBarManager] Switched to fallback output: \(firstAvailable.name)")

                // NEW: Restart audio if it was running
                if wasRunning {
                    audioManager.start()
                    print("[MenuBarManager] ✅ Audio engine restarted on fallback device")
                }
            }
        } catch {
            print("[MenuBarManager] Failed to switch to fallback output: \(error)")
        }
    } else {
        selectedOutputDevice = nil
        print("[MenuBarManager] No outputs available after disconnect")
    }

    updateMenu()
}
```

## Expected Behavior After Fix
Device disconnect → Audio switches to fallback device → Audio resumes automatically

## Test
1. Start audio with headphones
2. Disconnect headphones
3. Audio should continue playing on fallback device (speakers/etc)
