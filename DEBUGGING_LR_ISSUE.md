# Debugging: Right-Panned Audio Sounds Left

## Problem
Right-panned audio appears to come from the left side.

## Diagnostic Steps

### 1. Check Console Logs

When you load an HRIR preset, look for these log messages:

```
[HRIRManager] Activating preset: YourPresetName
[HRIRManager] HRIR channels: X, Input layout: Stereo
[HRIRManager] Auto-detected interleaved pair mapping for Y speakers
[HRIRManager] ✓ Input[0] 'Front Left' → HRIR L:0 R:1
[HRIRManager] ✓ Input[1] 'Front Right' → HRIR L:2 R:3
[HRIRManager]   HRIR[0] samples: [...]
[HRIRManager]   HRIR[1] samples: [...]
[HRIRManager]   HRIR[2] samples: [...]
[HRIRManager]   HRIR[3] samples: [...]
```

**Expected for stereo with 4-channel HRIR:**
- Input[0] (Left) should map to HRIR channels 0 and 1
- Input[1] (Right) should map to HRIR channels 2 and 3

### 2. Verify HRIR File Format

Your HRIR file should be organized as:
- **Channel 0**: Left speaker → Left ear
- **Channel 1**: Left speaker → Right ear
- **Channel 2**: Right speaker → Left ear
- **Channel 3**: Right speaker → Right ear

### 3. Common Issues

#### Issue A: HRIR Channels Are Swapped
Some HRIR files have the format:
- Ch 0: Left speaker → Left ear
- Ch 1: Right speaker → Left ear  ← WRONG ORDER
- Ch 2: Left speaker → Right ear
- Ch 3: Right speaker → Right ear

**Solution**: Use a custom mapping or reorder the HRIR file.

#### Issue B: Left/Right Ears Are Swapped in HRIR
The HRIR file might have:
- Ch 0: Left speaker → **Right** ear  ← SWAPPED
- Ch 1: Left speaker → **Left** ear   ← SWAPPED

**Solution**: Swap the channel assignments in code or fix the HRIR file.

#### Issue C: Output Channels Are Swapped
The audio output device might have left/right swapped.

**Test**: Play a test tone in passthrough mode (convolution OFF) and verify left/right are correct.

### 4. Quick Test

**Test 1: Passthrough Mode**
1. Disable convolution
2. Play left-panned audio → should hear in left ear
3. Play right-panned audio → should hear in right ear

If this works correctly, the issue is in the HRIR processing.

**Test 2: Check HRIR Sample Data**
Look at the logged samples:
- HRIR[0] and HRIR[2] should have different patterns (left vs right speaker)
- If they look identical, the HRIR file might be mono or corrupted

### 5. Temporary Fix: Swap Channels

If the issue is confirmed to be swapped HRIR channels, add this temporary fix:

In `HRIRManager.swift`, around line 195, swap the indices:

```swift
// TEMPORARY FIX: Swap left/right ear indices
let leftEarIR = wavData.audioData[rightEarIdx]  // Swapped!
let rightEarIR = wavData.audioData[leftEarIdx]  // Swapped!
```

### 6. Proper Fix: Custom Mapping

Create a custom mapping file:

```
# Custom HRIR Mapping (if your file has non-standard order)
FL = 0, 1
FR = 2, 3
```

Or if channels are swapped:

```
# Swapped HRIR Mapping
FL = 1, 0  # Swap left/right ear for left speaker
FR = 3, 2  # Swap left/right ear for right speaker
```

## Expected Behavior

When playing **right-panned audio**:
1. Input channel 1 (FR) receives the signal
2. Signal is convolved with HRIR[2] (FR → Left ear)
3. Signal is convolved with HRIR[3] (FR → Right ear)
4. HRIR[3] should have **stronger/earlier** response (direct path)
5. HRIR[2] should have **weaker/delayed** response (cross path)
6. Result: Perception of sound from the right

If HRIR[2] is stronger than HRIR[3], the sound will appear to come from the left!

## Diagnostic Command

Run the app and check the console output. Share the log lines starting with `[HRIRManager]` to diagnose further.

## Next Steps

1. ✅ Build succeeded with debug logging
2. 🔄 Run the app
3. 🔄 Load your HRIR preset
4. 🔄 Check console logs
5. 🔄 Share the log output

Based on the logs, we can determine:
- If the mapping is correct
- If the HRIR file has the expected format
- If channels need to be swapped
