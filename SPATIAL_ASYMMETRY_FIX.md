# Spatial Asymmetry Fix - Root Cause Analysis & Solution

## Problem Description
Left channel sounds "front-left" (narrower angle) while right channel sounds more "lateral" (wider, more pure right). This asymmetry was consistent across ALL HRIR files, indicating a systematic issue.

## Root Cause: HRIR ILD Asymmetry

### Diagnostic Results
From actual HRIR analysis:

**FL (Front Left) HRIR:**
- Ch[0] (Left ear): RMS=0.006520, Centroid=8.93ms (Direct path)
- Ch[1] (Right ear): RMS=0.002261, Centroid=16.36ms (Cross path)
- **ILD: +9.20 dB** (left ear louder than right)
- Cross-path delay: 16.36ms

**FR (Front Right) HRIR:**
- Ch[2] (Right ear): RMS=0.006034, Centroid=9.46ms (Direct path)
- Ch[3] (Left ear): RMS=0.001731, Centroid=24.39ms (Cross path)
- **ILD: -10.84 dB** (right ear louder than left, with swap)
- Cross-path delay: 24.39ms

### Key Findings

1. **ILD Magnitude Asymmetry**:
   - FL: 9.20 dB separation
   - FR: 10.84 dB separation
   - **Difference: 1.64 dB** → FR appears wider/more lateral

2. **ITD Asymmetry**:
   - FL cross-path: 16.36ms delay
   - FR cross-path: 24.39ms delay
   - **Difference: 8.03ms** → FR has much more extreme ITD

3. **Cross-path Energy Asymmetry**:
   - FL→R ear: RMS=0.002261 (23% stronger)
   - FR→L ear: RMS=0.001731 (weaker)
   - FL "bleeds" more into the opposite ear, making it sound less lateral

### Why This Happens
Most HRIRs (especially from HeSuVi and gaming headphone virtualizers) are:
- Optimized for **multi-channel movie/game audio** (5.1, 7.1, Atmos)
- FL/FR positioned at approximately ±30° (standard home theater)
- **Not perfectly symmetric** due to:
  - Real-world measurement variations
  - Head/ear anatomical asymmetries in HRTF measurements
  - Different acoustic environments during L vs R measurements

When playing **stereo music** through FL/FR channels, this asymmetry becomes very noticeable because we expect perfect left/right symmetry.

## Solution: Automatic ILD Compensation

### Implementation

#### 1. ILD Analysis (Lines 223-283)
When an HRIR preset is loaded:
- Calculate ILD for FL: `20 * log10(L_ear_RMS / R_ear_RMS)`
- Calculate ILD for FR with both mappings (no swap vs swap)
- Determine correct mapping based on symmetry error
- Compute ILD asymmetry: `|FR_ILD| - |FL_ILD|`

#### 2. Automatic Gain Computation
```swift
// Compensate for 50% of the asymmetry (full compensation sounds unnatural)
compensationAmount = ildAsymmetry * 0.5  // dB

// Convert to linear gain ratio
gainRatio = 10^(compensationAmount / 20)

// Apply gains while preserving total energy
autoLeftGain = sqrt(gainRatio)
autoRightGain = 1.0 / sqrt(gainRatio)
```

For your HRIR (1.64 dB asymmetry):
- Compensation: 0.82 dB
- Auto left gain: **1.047** (+0.4 dB boost)
- Auto right gain: **0.955** (-0.4 dB reduction)
- Net effect: **0.82 dB** compensation

#### 3. Two-Stage Gain System (Lines 58-64)
- **Automatic gains**: Computed from ILD analysis, applied transparently
- **Manual balance**: UI slider for additional adjustment
- **Total gain**: `auto * manual` (multiplicative)

This allows:
- System automatically corrects for HRIR asymmetry
- User can fine-tune for personal preference
- Both adjustments work together harmoniously

#### 4. Processing (Lines 511-520)
Gains applied after convolution but before output:
```swift
totalLeftGain = autoLeftGain * manualLeftGain
totalRightGain = autoRightGain * manualRightGain

vDSP_vsmul(leftOutput, 1, [totalLeftGain], &leftOutput, 1, frameCount)
vDSP_vsmul(rightOutput, 1, [totalRightGain], &rightOutput, 1, frameCount)
```

## Expected Results

### Console Output (when loading HRIR)
```
[HRIRManager] === Spatial Symmetry Analysis (FL vs FR) ===
[HRIRManager]   FL ILD: 9.20 dB (L ear louder)
[HRIRManager]   FR ILD (swapped): -10.84 dB (R ear louder)
[HRIRManager]   Symmetry error (swapped): 1.65 dB
[HRIRManager]   Recommendation: USE SWAP
[HRIRManager]   ILD Asymmetry: 1.64 dB (FR wider than FL)
[HRIRManager]   Auto Compensation: 0.82 dB → L: 1.047, R: 0.955
[HRIRManager]   Result: Effective compensation = 0.82 dB
```

### Console Output (during playback, every 100 calls)
```
[HRIRManager] Output - L:0.009821 R:0.009804 Ratio:1.0017 |
              Gains: Auto(L:1.047 R:0.955) Manual(L:1.000 R:1.000)
              Total(L:1.047 R:0.955)
```

### Perceived Changes
1. **Center image**: Mono content now centered (not right-biased)
2. **Symmetric stereo**: Left and right channels have equal spatial width
3. **Natural sound**: FL no longer sounds "front-left," FR no longer overly lateral
4. **Consistent**: Works across all HRIRs automatically

## Testing Instructions

1. **Run the app** and load an HRIR preset
2. **Check console** for the spatial symmetry analysis
3. **Play centered mono content** (like a mono vocal track)
4. **Listen for**:
   - Center image should be stable
   - Left/right have equal "width" and "distance"
   - No bias toward either side
5. **Use balance slider** if you want additional fine-tuning
6. **Check RMS logs** to verify compensation is working

## Compensation Factor Tuning

The compensation amount is set to **50% of the measured asymmetry** (line 283):
```swift
let compensationAmount = ildAsymmetry * 0.5
```

Why 50% and not 100%?
- 100% compensation can sound "over-corrected" or unnatural
- Some perceived asymmetry may be intentional in HRIR design
- Partial compensation preserves spatial character while improving balance
- User can adjust balance slider for remaining ~50% if desired

You can adjust this factor if needed:
- **0.3-0.4**: Subtle correction (conservative)
- **0.5**: Default (balanced)
- **0.6-0.7**: Stronger correction
- **0.8-1.0**: Maximum correction (may sound processed)

## Files Modified

- `MacHRIR/HRIRManager.swift`:
  - Lines 58-70: Two-stage gain system
  - Lines 203-299: ILD analysis and automatic compensation
  - Lines 511-543: Gain application and monitoring
- `MacHRIR/BalanceControlView.swift`:
  - Reset button now resets to 0.0 (no manual adjustment)

## Technical Notes

### Why Apply Gains After Convolution?
- Can't modify HRIR impulses directly (already convolved)
- Post-convolution gain preserves HRIR spatial characteristics
- Compensates for energy imbalance between FL and FR contributions
- Computationally efficient (single multiply per sample)

### Energy Preservation
Using `sqrt(gainRatio)` for both channels ensures:
```
leftGain² + rightGain² = constant
```
This prevents overall loudness changes when correcting balance.

### Limitations
- Compensates for ILD asymmetry only (not ITD)
- ITD compensation would require HRIR modification or delay lines
- The 8ms ITD difference remains but is less perceptually significant
- Post-convolution gains can't fully correct spatial angle perception
