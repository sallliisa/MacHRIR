# Quick Reference: Multi-Channel HRIR Formulas

## Core Mixing Formula

For **N** input channels and **2** output channels (binaural stereo):

```
For each block of 512 samples:
    
    LeftOutput[0..511] = 0
    RightOutput[0..511] = 0
    
    For i = 0 to N-1:
        speaker = InputLayout.channels[i]
        (hrirL_idx, hrirR_idx) = HRIRMap[speaker]
        
        LeftOutput += Convolve(Input[i], HRIR[hrirL_idx])
        RightOutput += Convolve(Input[i], HRIR[hrirR_idx])
```

## Channel Mapping Formats

### Format 1: Interleaved Pairs (HeSuVi Standard)
```
HRIR Channel Index = SpeakerIndex × 2 + EarIndex
where EarIndex: 0 = Left Ear, 1 = Right Ear

Example for 7.1 (8 speakers):
    FL:  Ch 0 (L), Ch 1 (R)
    FR:  Ch 2 (L), Ch 3 (R)
    FC:  Ch 4 (L), Ch 5 (R)
    LFE: Ch 6 (L), Ch 7 (R)
    BL:  Ch 8 (L), Ch 9 (R)
    BR:  Ch 10 (L), Ch 11 (R)
    SL:  Ch 12 (L), Ch 13 (R)
    SR:  Ch 14 (L), Ch 15 (R)
    
Total HRIR channels = 16
```

### Format 2: Split Blocks
```
Left Ear HRIR Index = SpeakerIndex
Right Ear HRIR Index = SpeakerIndex + SpeakerCount

Example for 7.1 (8 speakers):
    FL:  Ch 0 (L), Ch 8 (R)
    FR:  Ch 1 (L), Ch 9 (R)
    FC:  Ch 2 (L), Ch 10 (R)
    LFE: Ch 3 (L), Ch 11 (R)
    BL:  Ch 4 (L), Ch 12 (R)
    BR:  Ch 5 (L), Ch 13 (R)
    SL:  Ch 6 (L), Ch 14 (R)
    SR:  Ch 7 (L), Ch 15 (R)
    
Total HRIR channels = 16
```

## Standard Input Layouts

### Stereo (2.0)
```swift
[FL, FR]
```

### 5.1 Surround
```swift
[FL, FR, FC, LFE, BL, BR]
```

### 7.1 Surround
```swift
[FL, FR, FC, LFE, BL, BR, SL, SR]
```

### 7.1.4 Atmos
```swift
[FL, FR, FC, LFE, BL, BR, SL, SR, TFL, TFR, TBL, TBR]
```

## HRIR Channel Count Calculation

```
Required HRIR Channels = SpeakerCount × 2

Examples:
    Stereo:    2 speakers × 2 ears = 4 channels
    5.1:       6 speakers × 2 ears = 12 channels
    7.1:       8 speakers × 2 ears = 16 channels
    7.1.4:     12 speakers × 2 ears = 24 channels
```

## Convolution Output Formula

For a single virtual speaker:

```
LeftEarOutput[t] = Σ(k=0 to L-1) Input[t-k] × HRIR_Left[k]
RightEarOutput[t] = Σ(k=0 to L-1) Input[t-k] × HRIR_Right[k]

where:
    L = HRIR length (samples)
    t = current time sample
    k = HRIR tap index
```

For multiple virtual speakers (accumulation):

```
FinalLeftOutput[t] = Σ(i=0 to N-1) LeftEarOutput_i[t]
FinalRightOutput[t] = Σ(i=0 to N-1) RightEarOutput_i[t]

where:
    N = number of input channels
    i = input channel index
```

## FFT Convolution (Overlap-Save)

```
BlockSize = 512
FFTSize = 2 × BlockSize = 1024

For each block:
    1. Construct input: [PreviousBlock | CurrentBlock]
    2. FFT(input) → InputFreq
    3. For each partition p:
        OutputFreq += InputFreq[p] × HRIRFreq[p]
    4. IFFT(OutputFreq) → output
    5. Extract valid samples: output[512..1023]
```

## Memory Requirements

```
Per ConvolutionEngine:
    HRIR samples: L × 4 bytes
    FFT buffers: 2 × FFTSize × 4 bytes
    FDL buffers: PartitionCount × FFTSize × 4 bytes
    
    Total ≈ L × 4 + 2 × 1024 × 4 + P × 1024 × 4
    
    For L=512, P=1:
        ≈ 2KB + 8KB + 4KB = 14KB per engine

Per Virtual Speaker:
    2 engines × 14KB = 28KB

For 7.1 (8 speakers):
    8 × 28KB = 224KB

For 7.1.4 (12 speakers):
    12 × 28KB = 336KB
```

## CPU Complexity

```
Per block convolution:
    Time = O(PartitionCount × FFTSize × log(FFTSize))
    
For 7.1 (8 channels, 16 engines):
    Operations per block ≈ 16 × P × 1024 × log₂(1024)
                         ≈ 16 × P × 1024 × 10
                         ≈ 163,840 × P operations
    
At 48kHz with 512-sample blocks:
    Blocks per second = 48000 / 512 ≈ 94
    Total ops/sec ≈ 15.4M × P operations
```

## Latency Calculation

```
Total Latency = SystemBufferSize + ConvolutionBlockSize

Example at 48kHz:
    System buffer: 512 samples = 10.67ms
    Convolution block: 512 samples = 10.67ms
    Total: 1024 samples = 21.33ms
```

## Normalization Factor

After IFFT in Overlap-Save:

```
ScaleFactor = 0.25 / FFTSize

For FFTSize = 1024:
    ScaleFactor = 0.25 / 1024 = 0.000244140625
```

## HeSuVi mix.txt Format

```
# Comment lines start with # or ;
SpeakerName = LeftEarIndex, RightEarIndex

Example:
FL = 0, 1
FR = 2, 3
FC = 4, 5
```

## Swift Code Snippets

### Create Interleaved Mapping
```swift
let speakers: [VirtualSpeaker] = [.FL, .FR, .FC, .LFE, .SL, .SR, .BL, .BR]
let map = HRIRChannelMap.interleavedPairs(speakers: speakers)
```

### Create Split Block Mapping
```swift
let speakers: [VirtualSpeaker] = [.FL, .FR, .FC, .LFE, .SL, .SR, .BL, .BR]
let map = HRIRChannelMap.splitBlocks(speakers: speakers)
```

### Parse Custom Mapping
```swift
let mixTxt = """
FL = 0, 1
FR = 2, 3
FC = 4, 5
"""
let map = try HRIRChannelMap.parseHeSuViFormat(mixTxt)
```

### Activate Preset
```swift
let layout = InputLayout.detect(channelCount: 8) // Auto-detect 7.1
hrirManager.activatePreset(
    preset,
    targetSampleRate: 48000,
    inputLayout: layout,
    hrirMap: nil // Auto-detect mapping
)
```

---

## Quick Troubleshooting

**No sound?**
- Check HRIR channel count = InputChannels × 2
- Verify mapping format matches HRIR file

**Wrong spatialization?**
- Try different mapping format (interleaved vs split)
- Check speaker order in InputLayout

**High CPU?**
- Reduce HRIR length
- Check for memory allocations in callback

**Clicks/pops?**
- Increase system buffer size
- Check for buffer underruns
