# MacHRIR Troubleshooting Guide

## Common Issues and Solutions

### HRIR File Loading Issues

#### Error: "AVAudioFile error -54" when selecting HRIR file

**Cause**: File permission error when accessing files outside the app's sandbox.

**Solution**: This has been fixed in the latest version with security-scoped resource access. If you still see this error:

1. **Verify the fix is applied**: Check that `ContentView.swift` includes:
   ```swift
   let gotAccess = url.startAccessingSecurityScopedResource()
   defer {
       if gotAccess {
           url.stopAccessingSecurityScopedResource()
       }
   }
   ```

2. **Alternative workaround**: Copy the HRIR file manually to:
   ```
   ~/Library/Application Support/MacHRIR/presets/
   ```
   Then restart the app - it will automatically detect the file.

3. **Check file permissions**:
   ```bash
   ls -l /path/to/your/hrir.wav
   chmod 644 /path/to/your/hrir.wav
   ```

#### Error: "Invalid channel count" or "Empty file"

**Cause**: HRIR file doesn't meet format requirements.

**Solution**: Ensure your HRIR file:
- Is a valid WAV file
- Has at least 1 channel
- Contains audio data (not empty)
- Is not corrupted

Test your WAV file:
```bash
afinfo /path/to/your/hrir.wav
```

Should show:
```
File type ID: WAVE
Data format: (format details)
Number of channels: 2 (or more)
```

### Audio Issues

#### No audio output

**Symptoms**: Audio is not playing through the output device, level meters show no activity.

**Solutions**:

1. **Check System Audio Settings**:
   - Open System Settings → Sound
   - Verify Output is set to "BlackHole 2ch"
   - Play some audio (music, video, etc.)

2. **Check MacHRIR Settings**:
   - Ensure Input Device is "BlackHole 2ch"
   - Ensure Output Device is your headphones/speakers
   - Click "Start" button
   - Check for error messages

3. **Verify BlackHole Installation**:
   ```bash
   system_profiler SPAudioDataType | grep -i blackhole
   ```
   Should show BlackHole 2ch device.

4. **Check Permissions**:
   - System Settings → Privacy & Security → Microphone
   - Ensure MacHRIR has microphone access
   - If not listed, the app may not have requested permission properly

#### Audio glitches, crackling, or dropouts

**Symptoms**: Audio plays but has intermittent clicks, pops, or silence.

**Solutions**:

1. **Reduce CPU Load**:
   - Close unnecessary applications
   - Check Activity Monitor for CPU usage
   - MacHRIR should use <10% CPU

2. **Check Sample Rates**:
   - Ensure input and output devices use the same sample rate
   - Use Audio MIDI Setup to verify:
     - BlackHole 2ch: 48000 Hz recommended
     - Output device: 48000 Hz recommended

3. **Try Smaller HRIR**:
   - Large HRIR files (>8192 samples) can cause high CPU usage
   - Try a shorter impulse response

4. **Buffer Underrun**:
   - Check Console.app for messages like "buffer underrun"
   - Circular buffer may be too small for your system

#### One channel silent (mono output)

**Symptoms**: Only hearing audio in left or right channel.

**Solutions**:

1. **Check HRIR File**:
   - Verify HRIR has at least 2 channels
   - Use `afinfo` to check channel count

2. **Check Output Device**:
   - Ensure output device is stereo
   - Test with system sounds to verify both channels work

### Device Selection Issues

#### Input/Output device not appearing in list

**Solutions**:

1. **Refresh Device List**:
   - Restart MacHRIR
   - Devices are enumerated at app launch

2. **Check Device Availability**:
   - Open Audio MIDI Setup
   - Verify device appears there
   - Try disconnecting and reconnecting the device

3. **Install Device Driver**:
   - Some audio interfaces require drivers
   - Install manufacturer's driver software

#### "Device disconnected" error during playback

**Solutions**:

1. **Physical Connection**:
   - Check USB/audio cables
   - Try different USB port
   - Avoid USB hubs if possible

2. **Automatic Recovery**:
   - MacHRIR should detect reconnection
   - If not, click Stop then Start

### Convolution Issues

#### Convolution toggle is disabled

**Cause**: No HRIR preset is loaded.

**Solution**:
1. Add an HRIR preset using "Add Preset" button
2. Select the preset from dropdown
3. Convolution toggle will become enabled

#### Audio sounds weird or distorted with convolution enabled

**Solutions**:

1. **Check HRIR Quality**:
   - Ensure HRIR file is not corrupted
   - Try a different HRIR preset
   - Verify HRIR sample rate matches your audio

2. **Disable Convolution**:
   - Toggle off to verify issue is related to HRIR
   - If audio sounds normal without convolution, HRIR is the issue

3. **Check Levels**:
   - Level meters should not be in red (clipping)
   - Reduce system volume if clipping occurs
   - Some HRIRs may have high gain

### Performance Issues

#### High CPU usage (>20%)

**Solutions**:

1. **Reduce HRIR Length**:
   - Shorter HRIRs use less CPU
   - Trim HRIR file to first 2048-4096 samples

2. **Check Block Size**:
   - Default is 512 samples
   - Larger block size = more latency but lower CPU

3. **Close Background Apps**:
   - Disable unnecessary audio plugins
   - Close other audio applications

#### High memory usage (>100MB)

**Cause**: Multiple HRIR presets loaded or very long HRIRs.

**Solution**:
1. Remove unused presets
2. Use shorter HRIR files
3. Restart MacHRIR to clear memory

### Build/Launch Issues

#### App crashes on launch

**Solutions**:

1. **Check Console Logs**:
   ```bash
   log show --predicate 'process == "MacHRIR"' --last 5m
   ```

2. **Reset Preferences**:
   ```bash
   rm ~/Library/Application\ Support/MacHRIR/settings.json
   ```

3. **Clear Derived Data**:
   - In Xcode: Product → Clean Build Folder
   - Or: `rm -rf ~/Library/Developer/Xcode/DerivedData/MacHRIR-*`

#### Microphone permission denied

**Cause**: Missing or incorrect Info.plist entry.

**Solution**:
1. Open project in Xcode
2. Select MacHRIR target → Info tab
3. Add "Privacy - Microphone Usage Description"
4. Rebuild and run
5. Grant permission when prompted

### Data/Settings Issues

#### Settings not persisting between launches

**Location**: `~/Library/Application Support/MacHRIR/settings.json`

**Solutions**:

1. **Check File Permissions**:
   ```bash
   ls -la ~/Library/Application\ Support/MacHRIR/
   chmod 644 ~/Library/Application\ Support/MacHRIR/settings.json
   ```

2. **Manually Edit Settings**:
   ```bash
   open ~/Library/Application\ Support/MacHRIR/settings.json
   ```

#### Presets disappeared

**Location**: `~/Library/Application Support/MacHRIR/presets/`

**Solutions**:

1. **Check Preset Directory**:
   ```bash
   ls -la ~/Library/Application\ Support/MacHRIR/presets/
   ```

2. **Restore Presets**:
   - Copy WAV files back to presets directory
   - Restart MacHRIR

3. **Check Metadata File**:
   ```bash
   cat ~/Library/Application\ Support/MacHRIR/presets/presets.json
   ```

## Debugging Tools

### Enable Verbose Logging

Check Console.app for MacHRIR logs:
1. Open Console.app
2. Filter by "MacHRIR"
3. Look for error messages or warnings

### Audio MIDI Setup

Essential for diagnosing audio issues:
1. Open `/Applications/Utilities/Audio MIDI Setup.app`
2. View configured devices
3. Check sample rates
4. Create aggregate devices if needed

### Activity Monitor

Check resource usage:
1. Open Activity Monitor
2. Find MacHRIR process
3. Monitor CPU and Memory usage
4. Normal: <10% CPU, <50MB memory

### Testing Commands

```bash
# Check BlackHole installation
system_profiler SPAudioDataType | grep -i blackhole

# List audio devices
system_profiler SPAudioDataType

# Check file info
afinfo /path/to/hrir.wav

# Monitor CoreAudio errors
log stream --predicate 'subsystem == "com.apple.coreaudio"'

# Check app support directory
ls -laR ~/Library/Application\ Support/MacHRIR/
```

## Getting Help

If issues persist:

1. **Collect Information**:
   - macOS version
   - Mac model (M1, M2, etc.)
   - Error messages from Console.app
   - Steps to reproduce

2. **Check Logs**:
   ```bash
   log show --predicate 'process == "MacHRIR"' --last 30m > ~/Desktop/machrir-log.txt
   ```

3. **File Issue**:
   - Include macOS version and Mac model
   - Attach Console logs
   - Describe exact steps to reproduce
   - Include error messages from UI

## Known Limitations

1. **Apple Silicon Only**: Intel Macs not currently supported
2. **No Auto-Reconnect on Wake**: Devices may need manual restart after sleep
3. **Manual System Audio Routing**: Must manually set system output to BlackHole
4. **Sample Rate Restrictions**: 44.1kHz and 48kHz work best
5. **Convolution Disabled During Preset Switch**: Brief silence when changing presets

## Advanced Troubleshooting

### Reset Everything

Complete reset if all else fails:

```bash
# Stop the app first, then:
rm -rf ~/Library/Application\ Support/MacHRIR/
rm -rf ~/Library/Caches/MacHRIR/
rm -rf ~/Library/Preferences/com.machrir.*
```

Then restart MacHRIR and reconfigure from scratch.

### Check CoreAudio Status

```bash
# Reset CoreAudio daemon (will restart all audio)
sudo killall coreaudiod

# Check for audio errors
log show --predicate 'subsystem == "com.apple.coreaudio"' --last 10m
```

### Verify Build

Ensure you have the latest build with all fixes:

```bash
cd /path/to/MacHRIR
git log -1 --oneline
xcodebuild -scheme MacHRIR -configuration Debug clean build
```
