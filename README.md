# MacHRIR - macOS System-Wide HRIR DSP

A macOS application that provides system-wide HRIR-based convolution for spatial audio through headphones. Similar to HeSuVi but designed specifically for macOS.

## Features

- System-wide audio processing with HRIR convolution
- Independent input/output device selection (doesn't change system defaults)
- Support for multi-channel HRIR WAV files
- Low-latency processing (<10ms target)
- Real-time audio level monitoring
- Preset management system
- Automatic sample rate conversion
- Clean SwiftUI interface

## Requirements

- macOS 12.0 or later
- Apple Silicon (ARM64)
- Xcode 14.0 or later
- BlackHole 2ch virtual audio device (recommended for input)

## Installation

### 1. Install BlackHole (Virtual Audio Device)

Download and install BlackHole 2ch from: https://github.com/ExistentialAudio/BlackHole

```bash
brew install blackhole-2ch
```

### 2. Build the Application

1. Open `MacHRIR.xcodeproj` in Xcode
2. Select your development team in the project settings
3. Build and run (⌘R)

### 3. Required Info.plist Permissions

Add the following key to your Info.plist (or in Xcode's Info tab):

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MacHRIR requires microphone access to capture audio from the selected input device for processing.</string>
```

**In Xcode:**
1. Select the MacHRIR target
2. Go to the "Info" tab
3. Add a new entry: "Privacy - Microphone Usage Description"
4. Set the value to: "MacHRIR requires microphone access to capture audio from the selected input device for processing."

## Usage

### Basic Setup

1. **Set System Audio Output to BlackHole 2ch:**
   - Go to System Settings → Sound
   - Under "Output", select "BlackHole 2ch"
   - All system audio will now route through MacHRIR

2. **Configure MacHRIR:**
   - **Input Device:** Select "BlackHole 2ch" (captures system audio)
   - **Output Device:** Select your headphones or speakers

3. **Add HRIR Preset:**
   - Click "Add Preset" button
   - Select a multi-channel WAV file containing HRIR impulse responses
   - The preset will be copied to `~/Library/Application Support/MacHRIR/presets`

4. **Activate Processing:**
   - Select your preset from the dropdown
   - Enable "Convolution" toggle
   - Click "Start" to begin processing

### HRIR File Format

MacHRIR supports multi-channel WAV files:

- **Minimum:** 1 channel (mono, will be duplicated for stereo)
- **Recommended:** 2+ channels (channels 0 and 1 used for Left/Right)
- **Sample Rate:** Any (will be resampled to match device sample rate)
- **Bit Depth:** 16-bit, 24-bit, or 32-bit float

**Channel Mapping:**
- Channel 0 → Left ear HRIR
- Channel 1 → Right ear HRIR
- Additional channels (2+) → Ignored

### Audio Level Meters

- **Input Meter:** Shows audio level from the input device (before processing)
- **Output Meter:** Shows processed audio level (after HRIR convolution)
- Color coding: Green (normal) → Yellow (high) → Red (clipping)

## Architecture

### Core Components

1. **AudioGraphManager** - Manages CoreAudio input/output units
   - Separate Audio Unit instances for input and output
   - Circular buffer for device clock decoupling
   - Real-time audio callbacks

2. **CircularBuffer** - Thread-safe ring buffer (65KB)
   - Decouples input/output streams
   - Handles clock drift between devices

3. **ConvolutionEngine** - Overlap-save FFT convolution
   - Low-latency DSP processing
   - Pre-computed frequency-domain HRIRs
   - Separate engines for L/R channels

4. **HRIRManager** - Preset management
   - WAV file loading and parsing
   - Sample rate conversion
   - Preset storage and retrieval

5. **AudioDevice** - CoreAudio device enumeration
   - Lists available input/output devices
   - Queries device capabilities

### Audio Flow

```
System Audio → BlackHole 2ch → Input Audio Unit → Input Callback
                                                        ↓
                                                  Circular Buffer
                                                        ↓
                                            HRIR Convolution (optional)
                                                        ↓
Output Callback ← Output Audio Unit ← Headphones/Speakers
```

## Technical Details

### Non-Interleaved Audio Format

MacHRIR uses non-interleaved (planar) audio format, which is the macOS default:
- Each channel has its own separate buffer
- Format flags: `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved`
- 32-bit float samples

### Sample Rate Handling

- Input and output devices may have different sample rates
- HRIRs are resampled to match the processing sample rate during loading
- High-quality sinc interpolation for HRIR resampling
- Circular buffer absorbs short-term clock drift

### Latency

Target latency: <10ms end-to-end

- Processing block size: 512 samples (~10ms at 48kHz)
- Circular buffer: 65536 bytes (~1.5 seconds at 48kHz stereo)
- Convolution: Overlap-save FFT method

## Project Structure

```
MacHRIR/
├── MacHRIRApp.swift              # App entry point
├── ContentView.swift             # Main UI
├── AudioGraphManager.swift       # CoreAudio management
├── CircularBuffer.swift          # Thread-safe ring buffer
├── AudioDevice.swift             # Device enumeration
├── ConvolutionEngine.swift       # FFT convolution
├── HRIRManager.swift             # Preset management
├── WAVLoader.swift               # WAV file parsing
├── Resampler.swift               # Sample rate conversion
├── SettingsManager.swift         # Settings persistence
└── LevelMeterView.swift          # Audio level visualization
```

## Troubleshooting

### HRIR file loading error (-54)

If you see "AVAudioFile error -54" when selecting an HRIR file:

**This has been fixed** - the app now properly requests security-scoped access to files. If you still encounter this:

1. Make sure you're using the latest build
2. Try copying the HRIR file to: `~/Library/Application Support/MacHRIR/presets/`
3. Restart the app - it will auto-detect the file

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for detailed solutions.

### No audio output
- Check that both input and output devices are selected
- Verify System Settings → Sound output is set to BlackHole 2ch
- Check audio level meters for signal presence
- Try clicking Stop then Start

### Audio glitches or dropouts
- Close unnecessary applications to reduce CPU load
- Check Console.app for error messages
- Verify sample rates match between devices
- Try a smaller HRIR file

### Device not appearing in list
- Disconnect and reconnect the device
- Restart MacHRIR
- Check that device is enabled in System Settings

### HRIR preset fails to load
- Verify WAV file format (must be valid WAV)
- Check that file has at least 1 channel
- Ensure file is not corrupted
- Check error message for details

**For comprehensive troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)**

## Known Limitations

- Apple Silicon only (no Intel support in current build)
- System audio must be routed to BlackHole manually
- No automatic device reconnection on wake from sleep
- Convolution disabled during preset switching

## Development

### Building from Source

```bash
git clone <repository-url>
cd MacHRIR
open MacHRIR.xcodeproj
```

### Testing Checklist

See `prompt.md` for comprehensive testing procedures including:
- Device selection testing
- Audio quality testing
- Stability testing
- Error handling testing

## License

MIT License - See LICENSE file for details

## Credits

- Based on specifications in `prompt.md` and `PASSTHROUGH_SPEC.md`
- Uses Apple's CoreAudio and Accelerate frameworks
- Inspired by HeSuVi (Windows HRIR convolution tool)

## Support

For issues and feature requests, please file an issue on GitHub.

## References

- [Apple Core Audio Documentation](https://developer.apple.com/documentation/coreaudio)
- [Audio Unit Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitProgrammingGuide/)
- [BlackHole Virtual Audio Driver](https://github.com/ExistentialAudio/BlackHole)
