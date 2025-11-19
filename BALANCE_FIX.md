# Balance Fix Implementation

## Problem
Subtle right-panning bias in binaural output when convolution is enabled. The issue was consistent across all HRIR files, indicating a systematic implementation issue rather than HRIR-specific problems.

## Root Cause Analysis
1. **Without channel swapping**: Strong LEFT bias (measured 1.54x, L:0.010403 R:0.006754)
2. **With channel swapping**: Slight RIGHT bias (user-reported, subjective)

The channel swapping in `VirtualSpeaker.swift` is NECESSARY to fix the major left bias, but it slightly overcorrects.

## Solution
Added fine-grained balance compensation system with both automatic and manual control:

### 1. Balance Compensation System (HRIRManager.swift)
- Added `leftChannelGain` and `rightChannelGain` properties (default: 1.0)
- Added `setBalance(_ balance: Float)` method:
  - Range: -1.0 (boost left) to +1.0 (boost right)
  - 0.0 = no adjustment
  - Uses ±15% max gain adjustment to preserve dynamic range
- Applied via `vDSP_vsmul()` after convolution processing

### 2. Default Compensation
- Set default balance to `-0.2` (3% left boost, 3% right reduction)
- This compensates for the slight right bias from channel swapping
- User can adjust this value in real-time

### 3. UI Control (BalanceControlView.swift)
- Added slider control in HRIR Presets section
- Range: -1.0 (L) to +1.0 (R) in 0.05 steps
- Displays current value numerically
- "Reset" button returns to default (-0.2)

### 4. Diagnostic Logging
- Measures RMS levels for left/right outputs every 100 processing calls
- Displays balance ratio in console:
  - 1.0 = perfectly balanced
  - >1.0 = left bias
  - <1.0 = right bias
- Logs current gain settings for debugging

## Files Modified
- `MacHRIR/HRIRManager.swift`: Added balance compensation system
- `MacHRIR/VirtualSpeaker.swift`: Kept channel swapping (necessary fix)
- `MacHRIR/ContentView.swift`: Added balance control to UI
- `MacHRIR/BalanceControlView.swift`: NEW - Balance control UI component

## Testing
1. Build and run the application
2. Enable convolution with any HRIR
3. Play centered mono content
4. Adjust balance slider to taste
5. Check console logs for RMS measurements

## Recommended Starting Values
- **Default**: -0.2 (slight left boost to counter right bias)
- **If still sounds right-panned**: Decrease to -0.3 or -0.4
- **If sounds left-panned**: Increase toward 0.0

## Technical Details
The balance is applied using Accelerate framework's `vDSP_vsmul()`:
```swift
leftChannelGain = 1.0 + abs(balance) * 0.15   // For negative balance
rightChannelGain = 1.0 - abs(balance) * 0.15  // For negative balance
```

This approach:
- Preserves total energy (one channel boosted, other attenuated)
- Uses hardware-accelerated SIMD operations
- Applies after convolution but before output (correct insertion point)
- Doesn't modify HRIR data or convolution algorithm
