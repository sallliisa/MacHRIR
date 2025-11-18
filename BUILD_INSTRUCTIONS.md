# MacHRIR Build Instructions

## Prerequisites

1. **macOS**: 12.0 or later
2. **Xcode**: 14.0 or later
3. **Architecture**: Apple Silicon (ARM64)
4. **BlackHole 2ch** (recommended virtual audio driver)

## Quick Start

### 1. Install BlackHole Virtual Audio Device

Install using Homebrew:

```bash
brew install blackhole-2ch
```

Or download from: https://github.com/ExistentialAudio/BlackHole

### 2. Configure Info.plist Permissions

**IMPORTANT**: Before building, you MUST add microphone permission to your app:

1. Open `MacHRIR.xcodeproj` in Xcode
2. Select the **MacHRIR** target in the project navigator
3. Go to the **Info** tab
4. Click the **+** button to add a new key
5. Select **Privacy - Microphone Usage Description**
6. Set the value to: `MacHRIR requires microphone access to capture audio from the selected input device for processing.`

Alternatively, you can add this directly to Info.plist:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MacHRIR requires microphone access to capture audio from the selected input device for processing.</string>
```

### 3. Build the Project

```bash
cd /Users/gamer/Documents/projects/MacHRIR
xcodebuild -scheme MacHRIR -configuration Debug build
```

Or open in Xcode and press **⌘R** to build and run.

### 4. Run the Application

1. Launch the MacHRIR app
2. In System Settings → Sound, set **Output** to "BlackHole 2ch"
3. In MacHRIR:
   - Select "BlackHole 2ch" as **Input Device**
   - Select your headphones/speakers as **Output Device**
4. Add an HRIR preset (WAV file)
5. Select the preset and enable "Convolution"
6. Click "Start"

## Project Structure

All source files are located in the `MacHRIR/` directory:

```
MacHRIR/
├── MacHRIRApp.swift              # App entry point
├── ContentView.swift             # Main UI
├── LevelMeterView.swift          # Audio level visualization
├── AudioGraphManager.swift       # CoreAudio input/output management
├── CircularBuffer.swift          # Thread-safe audio buffer
├── AudioDevice.swift             # Device enumeration
├── ConvolutionEngine.swift       # FFT-based convolution
├── HRIRManager.swift             # Preset management
├── WAVLoader.swift               # WAV file loading
├── Resampler.swift               # Sample rate conversion
└── SettingsManager.swift         # Settings persistence
```

## Build Configuration

### Debug Build

```bash
xcodebuild -scheme MacHRIR -configuration Debug build
```

Product location: `~/Library/Developer/Xcode/DerivedData/MacHRIR-*/Build/Products/Debug/MacHRIR.app`

### Release Build

```bash
xcodebuild -scheme MacHRIR -configuration Release build
```

Product location: `~/Library/Developer/Xcode/DerivedData/MacHRIR-*/Build/Products/Release/MacHRIR.app`

## Code Signing

For distribution, you'll need to configure code signing:

1. Open project in Xcode
2. Select MacHRIR target → Signing & Capabilities
3. Select your Team
4. Ensure "Automatically manage signing" is checked

## Common Build Issues

### Issue: "NSMicrophoneUsageDescription required"

**Solution**: Add the microphone usage description to Info.plist (see step 2 above)

### Issue: "Building for 'macOS', but linking in object file built for 'iOS'"

**Solution**: Ensure deployment target is set to macOS 12.0 or later:
- Select project → Build Settings
- Search for "macOS Deployment Target"
- Set to 12.0 or higher

### Issue: Build fails with audio API errors

**Solution**: Make sure you're building for Apple Silicon (ARM64):
- Select project → Build Settings
- Search for "Architectures"
- Ensure "arm64" is selected

## Testing the Build

After building successfully:

1. **Check audio passthrough**:
   - Play audio (e.g., music or video)
   - Verify you hear the audio through selected output device
   - Check level meters show activity

2. **Test device selection**:
   - Try switching input and output devices
   - Verify audio continues working after device change

3. **Test HRIR loading**:
   - Add a test HRIR WAV file
   - Enable convolution
   - Verify processed audio sounds different (spatial effect)

## Performance

Target performance metrics:

- **Latency**: <10ms end-to-end
- **CPU Usage**: <10% on Apple M1/M2 (single thread)
- **Memory**: <50MB runtime
- **Sample Rates**: 44.1kHz and 48kHz supported

## Troubleshooting

### No audio output

1. Verify System Settings → Sound output is set to BlackHole 2ch
2. Check that both input and output devices are selected in MacHRIR
3. Look for error messages in the app
4. Check Console.app for crash logs or error messages

### Audio glitches/dropouts

1. Close unnecessary applications
2. Check CPU usage in Activity Monitor
3. Try a smaller HRIR file
4. Verify sample rates match between devices

### Build warnings

Some warnings about optimization are expected and can be ignored. Critical warnings will prevent the build from succeeding.

## Architecture Notes

**Key Design Decisions**:

1. **CoreAudio over AVAudioEngine**: Uses CoreAudio directly with separate Audio Units for independent device selection (see PASSTHROUGH_SPEC.md)

2. **Non-Interleaved Audio**: macOS default format with separate buffers per channel

3. **Circular Buffer**: 65KB ring buffer decouples input/output clock domains

4. **Overlap-Save FFT**: Efficient convolution with minimal latency

## Next Steps

After successful build:

1. Test with various audio sources
2. Try different HRIR presets
3. Monitor CPU and memory usage
4. Test device hot-plugging
5. Verify settings persistence

## References

- [Technical Specification](prompt.md)
- [Audio Passthrough Details](PASSTHROUGH_SPEC.md)
- [Project README](README.md)
- [Apple CoreAudio Documentation](https://developer.apple.com/documentation/coreaudio)

## Support

For build issues:
1. Check Console.app for detailed error messages
2. Verify all prerequisites are met
3. Try cleaning the build folder (Product → Clean Build Folder in Xcode)
4. File an issue on GitHub with build logs
