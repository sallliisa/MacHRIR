# MacHRIR Changelog

## [Unreleased] - 2025-01-19

### Fixed

#### Critical: Very Quiet Audio Output
**Problem**: Audio passthrough was extremely quiet, even at maximum volume.

**Root Cause**: Incorrect channel handling in circular buffer. The input callback was writing each channel's data sequentially (Channel 0 data, then Channel 1 data), but the output callback was reading them as if they were properly interleaved. This resulted in:
- Channel 0 output: Half of Channel 0 data + half of Channel 1 data
- Channel 1 output: Half of Channel 1 data + half of silence/next buffer

This caused severe volume loss (~50% of samples were from the wrong channel or silence).

**Solution**: Implemented proper interleaving/de-interleaving:

1. **Input Callback**: Now interleaves channel data before writing to circular buffer
   ```
   Format: [Frame0-Ch0, Frame0-Ch1, Frame1-Ch0, Frame1-Ch1, ...]
   ```

2. **Output Callback**: Now de-interleaves data when reading from circular buffer
   ```
   Buffer -> [Frame0-Ch0, Frame0-Ch1, ...] -> Ch0: [Frame0, Frame1, ...]
                                             -> Ch1: [Frame0, Frame1, ...]
   ```

3. **Performance Optimization**: Pre-allocated interleave buffers to avoid heap allocations in real-time audio callbacks

**Files Modified**:
- `AudioGraphManager.swift`:
  - Added `inputInterleaveBuffer` and `outputInterleaveBuffer` properties
  - Updated `inputRenderCallback()` to interleave before writing
  - Updated `outputRenderCallback()` to de-interleave after reading

**Expected Behavior After Fix**:
- Audio should now be at normal volume
- Both channels should contain correct data
- Level meters should show appropriate levels

---

#### File Access Permissions (Error -54)
**Problem**: When selecting HRIR files via file picker, AVAudioFile reported error -54 (permission denied).

**Root Cause**: macOS sandbox restrictions prevented access to files outside the app's container without security-scoped access.

**Solution**: Implemented security-scoped resource access:
```swift
let gotAccess = url.startAccessingSecurityScopedResource()
defer {
    if gotAccess {
        url.stopAccessingSecurityScopedResource()
    }
}
// Access file...
```

**Files Modified**:
- `ContentView.swift`: Added security-scoped access in file importer callback

**Expected Behavior After Fix**:
- HRIR files can be selected from anywhere on the system
- Files are copied to app's Application Support directory for future access
- No permission errors when loading presets

---

### Performance Improvements

#### Real-Time Audio Callback Optimization
**Changes**:
- Pre-allocated interleave buffers (8192 samples each) to eliminate heap allocations in audio callbacks
- Buffers are allocated once during `AudioGraphManager` initialization
- Reused for every audio callback, ensuring zero allocations in real-time thread

**Impact**:
- Reduced CPU usage in audio callbacks
- Eliminated potential glitches from heap allocations
- Better compliance with real-time audio best practices

---

#### Critical: Replaced FFT Convolution with vDSP_conv
**Problem**: FFT-based overlap-save convolution caused infinite HALC overload errors (skipping cycles due to overload), indicating the convolution was too slow for real-time audio processing.

**Root Cause**: The FFT approach (forward FFT → complex multiply → inverse FFT) was too computationally expensive for 512-sample blocks at 48kHz (~10ms deadline). Even with no array allocations, the FFT operations couldn't complete in time.

**Solution**: Completely rewrote `ConvolutionEngine.swift` to use Accelerate framework's `vDSP_conv`:

1. **Time-Domain Convolution**: Direct convolution using Apple's hardware-accelerated `vDSP_conv` function
   ```swift
   vDSP_conv(
       input, 1,           // Input signal
       hrir, 1,            // HRIR kernel (impulse response)
       &convResult, 1,     // Output
       vDSP_Length(blockSize),     // Length of input
       vDSP_Length(hrirLength)     // Length of kernel
   )
   ```

2. **Overlap-Add Method**: Properly handles convolution tails between blocks
   - Each convolution produces `blockSize + hrirLength - 1` samples
   - First `blockSize` samples are output
   - Remaining `hrirLength - 1` samples are saved and added to next block

3. **Simplified Architecture**: Reduced from ~200 lines (FFT) to ~100 lines (vDSP_conv)
   - No FFT setup or buffer management
   - No complex number operations
   - Direct use of Apple's optimized implementation

**Files Modified**:
- `ConvolutionEngine.swift`: Complete rewrite using vDSP_conv
- `HRIRManager.swift`: Re-enabled actual convolution processing

**Expected Behavior After Fix**:
- No HALC overload errors with convolution enabled
- Real-time performance with HRIRs up to ~1024 samples
- Audible spatial audio effect when toggling convolution

**Performance Notes**:
- vDSP_conv is hardware-accelerated on Apple Silicon
- Should work well for typical HRIRs (256-512 samples)
- If HRIRs are very long (>1024 samples), may need truncation or separate thread

---

## Testing

### Volume Fix Verification

1. **Before Fix**:
   ```
   Input Level:  ████████████████████ (normal)
   Output Level: ██░░░░░░░░░░░░░░░░░░ (very quiet)
   Perceived Volume: ~10% of expected
   ```

2. **After Fix**:
   ```
   Input Level:  ████████████████████ (normal)
   Output Level: ████████████████████ (normal)
   Perceived Volume: 100% (matches input)
   ```

### Test Procedure

1. **Build Latest Version**:
   ```bash
   xcodebuild -scheme MacHRIR -configuration Debug build
   ```

2. **Test Audio Passthrough**:
   - Set System Sound output to BlackHole 2ch
   - Launch MacHRIR
   - Select BlackHole 2ch as input
   - Select headphones as output
   - Click Start
   - Play music/video
   - **Expected**: Audio at normal volume, matches system volume

3. **Test Level Meters**:
   - Input meter should show activity
   - Output meter should show similar activity
   - Both should reach similar peak levels

4. **Test HRIR Loading**:
   - Click "Add Preset"
   - Select HRIR WAV file from Downloads or Documents
   - **Expected**: No error -54, file loads successfully

5. **Test HRIR Convolution** (NEW):
   - Load an HRIR preset (step 4)
   - Select the preset from the "Active Preset" dropdown
   - Toggle "Convolution" switch ON
   - Play hard-panned audio (e.g., a stereo test track with L/R separation)
   - **Expected**:
     - Audio should change noticeably when convolution is toggled
     - Hard-panned audio should appear more spatially diffuse
     - No HALC overload errors in Console.app
     - No audio dropouts or glitches
     - Output level meter should remain similar to input
   - Toggle convolution OFF
   - **Expected**: Audio returns to original passthrough sound

---

## Known Issues

None currently identified. Please report any issues encountered.

---

## Migration Notes

### For Users

No manual migration needed. Simply rebuild and run the latest version.

**Recommended Actions**:
1. Stop audio playback
2. Rebuild the app
3. Launch new version
4. Test with a known audio source
5. Verify volume is now normal

### For Developers

If you've made custom modifications:

1. **Circular Buffer Usage**: Now expects interleaved data
   - Input: Write interleaved samples [L, R, L, R, ...]
   - Output: Read interleaved, then de-interleave

2. **Pre-allocated Buffers**: `inputInterleaveBuffer` and `outputInterleaveBuffer`
   - Size: `maxFramesPerCallback * 2` (4096 * 2 = 8192 samples)
   - Reused every callback
   - Ensure sufficient size for your use case

---

## Version History

- **v0.3** (2025-01-19): Replaced FFT convolution with vDSP_conv for real-time performance
- **v0.2** (2025-01-19): Fixed critical volume issue and file access permissions
- **v0.1** (2025-01-19): Initial implementation
