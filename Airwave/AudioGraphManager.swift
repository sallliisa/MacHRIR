//
//  AudioGraphManager.swift
//  Airwave
//
//  Manages CoreAudio graph with single aggregate device support
//

import Foundation
import CoreAudio
import AVFoundation
import Combine
import Accelerate

/// Manages audio I/O using a single HAL Audio Unit for an aggregate device
class AudioGraphManager: ObservableObject {

    // MARK: - Singleton
    static let shared = AudioGraphManager()

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var aggregateDevice: AudioDevice?
    @Published var errorMessage: String?
    
    // Output device selection state (shared between MenuBarManager and SettingsView)
    @Published var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] = []
    @Published var selectedOutputDevice: AggregateDeviceInspector.SubDeviceInfo?
    
    // Input device selection state
    @Published var availableInputs: [AggregateDeviceInspector.SubDeviceInfo] = []
    @Published var selectedInputDevice: AggregateDeviceInspector.SubDeviceInfo?
    
    // MARK: - Private Properties

    fileprivate var audioUnit: AudioUnit?
    
    // Device properties
    fileprivate var inputChannelCount: UInt32 = 0
    fileprivate var outputChannelCount: UInt32 = 2
    
    // Track which output channels to use
    var selectedOutputChannelRange: Range<Int>?
    
    // Track which input channels to use (first 2 channels from selected input device)
    var selectedInputChannelRange: Range<Int>?
    
    fileprivate var currentSampleRate: Double = 48000.0

    // Pre-allocated buffers for multi-channel processing
    fileprivate let maxFramesPerCallback: Int = 4096
    fileprivate let maxChannels: Int = 64  // Support up to 64 channels (multiple multi-channel devices in aggregate)
    
    // Multi-channel buffers using UnsafeMutablePointer for zero-allocation real-time processing
    fileprivate var inputChannelBufferPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    fileprivate var outputStereoLeftPtr: UnsafeMutablePointer<Float>!
    fileprivate var outputStereoRightPtr: UnsafeMutablePointer<Float>!
    
    // Pre-allocated AudioBufferList for Input Callback (Element 1)
    fileprivate var inputAudioBufferListPtr: UnsafeMutableRawPointer?
    // Array of pointers to raw audio buffers
    fileprivate var inputAudioBuffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>?

    // Reference to HRIR manager for convolution
    var hrirManager: HRIRManager?

    // MARK: - Initialization

    init() {
        // Pre-allocate AudioBufferList for input rendering
        let bufferListSize = MemoryLayout<AudioBufferList>.size +
                             max(0, maxChannels - 1) * MemoryLayout<AudioBuffer>.size
        
        inputAudioBufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        
        // Pre-allocate per-channel audio data buffers (raw bytes for AudioUnit)
        inputAudioBuffersPtr = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: maxChannels)
        
        for i in 0..<maxChannels {
            let byteCount = maxFramesPerCallback * MemoryLayout<Float>.size
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: 16
            )
            memset(buffer, 0, byteCount)
            inputAudioBuffersPtr![i] = buffer
        }

        // Pre-allocate per-channel buffers using UnsafeMutablePointer for processing
        inputChannelBufferPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: maxChannels)
        
        for i in 0..<maxChannels {
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
            ptr.initialize(repeating: 0, count: maxFramesPerCallback)
            inputChannelBufferPtrs![i] = ptr
        }
        
        // Allocate output stereo buffers
        outputStereoLeftPtr = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        outputStereoLeftPtr.initialize(repeating: 0, count: maxFramesPerCallback)
        
        outputStereoRightPtr = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        outputStereoRightPtr.initialize(repeating: 0, count: maxFramesPerCallback)
    }

    deinit {
        stop()
        
        // Deallocate Input AudioBufferList
        inputAudioBufferListPtr?.deallocate()
        
        // Deallocate Input Audio Buffers
        if let buffersPtr = inputAudioBuffersPtr {
            for i in 0..<maxChannels {
                buffersPtr[i].deallocate()
            }
            buffersPtr.deallocate()
            inputAudioBuffersPtr = nil
        }
        
        // Deallocate channel buffers
        if let channelsPtr = inputChannelBufferPtrs {
            for i in 0..<maxChannels {
                channelsPtr[i].deallocate()
            }
            channelsPtr.deallocate()
            inputChannelBufferPtrs = nil
        }
        
        outputStereoLeftPtr?.deallocate()
        outputStereoRightPtr?.deallocate()
    }

    // MARK: - Public Methods

    /// Start the audio engine with selected aggregate device
    func start() {
        // Check diagnostics first - prevent start if not fully configured
        let diagnostics = SystemDiagnosticsManager.shared.diagnostics
        guard diagnostics.isFullyConfigured else {
            errorMessage = "Complete all diagnostics setup steps before starting"
            Logger.log("[AudioGraph] Start prevented: Diagnostics not fulfilled")
            return
        }
        
        guard let device = aggregateDevice else {
            errorMessage = "Please select an aggregate device"
            return
        }
        
        // Validate that device still exists
        let allDevices = AudioDeviceManager.getAllDevices()
        guard allDevices.contains(where: { $0.id == device.id }) else {
            errorMessage = "Device '\(device.name)' is no longer available"
            return
        }

        stop()
        
        // Switch system audio to the selected input device BEFORE starting engine
        // This prevents any audio blast on the physical device
        switchSystemAudioToInputDevice()

        do {
            try setupAudioUnit(device: device, outputChannelRange: selectedOutputChannelRange)

            // Notify HRIR manager of the input layout
            // We assume the first N channels of the aggregate device are the input channels
            if let hrirManager = hrirManager, let activePreset = hrirManager.activePreset {
                // Heuristic: Use the device's total input channels as the source layout
                // Users should configure aggregate device to have multi-channel input first
                let inputLayout = InputLayout.detect(channelCount: Int(inputChannelCount))
                hrirManager.activatePreset(
                    activePreset,
                    targetSampleRate: currentSampleRate,
                    inputLayout: inputLayout
                )
            }

            let status = AudioOutputUnitStart(audioUnit!)
            guard status == noErr else {
                throw AudioError.startFailed(status, "Failed to start audio unit")
            }

            DispatchQueue.main.async {
                self.isRunning = true
                self.errorMessage = nil
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
                self.isRunning = false
            }
        }
    }

    /// Stop the audio engine
    func stop() {
        // Restore system audio output before stopping engine
        restoreSystemAudioToSelected()
        
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    /// Setup with aggregate device and optional output channel specification
    func setupAudioUnit(
        aggregateDevice: AudioDevice,
        outputChannelRange: Range<Int>? = nil
    ) throws {
        self.aggregateDevice = aggregateDevice
        self.selectedOutputChannelRange = outputChannelRange
        try setupAudioUnit(device: aggregateDevice, outputChannelRange: outputChannelRange)
    }

    /// Change output routing without stopping audio
    /// If the aggregate device configuration has changed, triggers a full reconfiguration
    func setOutputChannels(_ range: Range<Int>) {
        // Check if reconfiguration is needed (aggregate device channel count changed)
        if needsReconfiguration() {
            Logger.log("[AudioGraph] 🔄 Aggregate device configuration changed - triggering reconfiguration")
            reconfigureAudioUnit(withOutputChannelRange: range)
            return
        }
        
        // Validate range against current output channel count
        guard range.upperBound <= Int(outputChannelCount) else {
            // The requested range exceeds our known channel count
            // This might mean the aggregate was modified - try reconfiguring
            Logger.log("[AudioGraph] ⚠️ Output range \(range) exceeds known channels (\(outputChannelCount)) - attempting reconfiguration")
            reconfigureAudioUnit(withOutputChannelRange: range)
            return
        }
        
        // Thread-safe update of output channel range
        selectedOutputChannelRange = range
        Logger.log("[AudioGraph] Output channels set to: \(range.lowerBound)-\(range.upperBound - 1)")
    }
    
    /// Change input routing without stopping audio
    func setInputChannels(_ range: Range<Int>) {
        // Note: We don't validate against inputChannelCount here because:
        // 1. The range comes from AggregateDeviceInspector which validates device existence
        // 2. inputChannelCount can become stale when sub-devices are added/removed from aggregate
        // 3. The render callback has its own safety checks
        selectedInputChannelRange = range
        Logger.log("[AudioGraph] Input channels set to: \(range.lowerBound)-\(range.upperBound - 1)")
    }
    
    /// Check if the AudioUnit needs reconfiguration due to aggregate device changes
    /// Returns true if the device's current channel count differs from our configured count
    func needsReconfiguration() -> Bool {
        guard let device = aggregateDevice else { return false }
        
        let currentOutputChannels = getCurrentDeviceOutputChannelCount(device: device)
        let currentInputChannels = getCurrentDeviceInputChannelCount(device: device)
        
        // If either channel count has changed, we need to reconfigure
        let needsReconfig = currentOutputChannels != outputChannelCount || currentInputChannels != inputChannelCount
        
        if needsReconfig {
            Logger.log("[AudioGraph] Configuration mismatch detected:")
            Logger.log("  - Output: configured=\(outputChannelCount), actual=\(currentOutputChannels)")
            Logger.log("  - Input: configured=\(inputChannelCount), actual=\(currentInputChannels)")
        }
        
        return needsReconfig
    }
    
    /// Reconfigure the AudioUnit with current aggregate device state
    /// Preserves running state - will restart if was running
    func reconfigureAudioUnit(withOutputChannelRange range: Range<Int>? = nil) {
        guard let device = aggregateDevice else {
            Logger.log("[AudioGraph] Cannot reconfigure - no aggregate device selected")
            return
        }
        
        let wasRunning = isRunning
        
        // Stop if running
        if wasRunning {
            // Stop without restoring system audio (we're just reconfiguring)
            if let unit = audioUnit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                audioUnit = nil
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
        
        // Reconfigure with new channel range or existing range
        let targetRange = range ?? selectedOutputChannelRange
        
        do {
            try setupAudioUnit(device: device, outputChannelRange: targetRange)
            
            // Update the stored range
            selectedOutputChannelRange = targetRange
            
            Logger.log("[AudioGraph] ✅ AudioUnit reconfigured successfully")
            Logger.log("  - New output channel count: \(outputChannelCount)")
            Logger.log("  - New input channel count: \(inputChannelCount)")
            Logger.log("  - Output range: \(targetRange?.description ?? "nil")")
            
            // Restart if was running
            if wasRunning {
                let status = AudioOutputUnitStart(audioUnit!)
                if status == noErr {
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.errorMessage = nil
                    }
                    Logger.log("[AudioGraph] ✅ AudioUnit restarted after reconfiguration")
                } else {
                    Logger.log("[AudioGraph] ❌ Failed to restart AudioUnit after reconfiguration: \(status)")
                }
            }
            
        } catch {
            Logger.log("[AudioGraph] ❌ Reconfiguration failed: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Reconfiguration failed: \(error.localizedDescription)"
            }
        }
    }
    
    /// Query the current output channel count from the aggregate device
    private func getCurrentDeviceOutputChannelCount(device: AudioDevice) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device.id, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr else { return 0 }
        
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        
        status = AudioObjectGetPropertyData(device.id, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard status == noErr else { return 0 }
        
        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        var totalChannels: UInt32 = 0
        
        for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
            let buffer = withUnsafePointer(to: bufferList.pointee.mBuffers) { ptr in
                ptr.advanced(by: i).pointee
            }
            totalChannels += buffer.mNumberChannels
        }
        
        return totalChannels
    }
    
    /// Query the current input channel count from the aggregate device
    private func getCurrentDeviceInputChannelCount(device: AudioDevice) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device.id, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr else { return 0 }
        
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        
        status = AudioObjectGetPropertyData(device.id, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard status == noErr else { return 0 }
        
        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        var totalChannels: UInt32 = 0
        
        for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
            let buffer = withUnsafePointer(to: bufferList.pointee.mBuffers) { ptr in
                ptr.advanced(by: i).pointee
            }
            totalChannels += buffer.mNumberChannels
        }
        
        return totalChannels
    }

    /// Select aggregate device
    func selectAggregateDevice(_ device: AudioDevice) {
        aggregateDevice = device
        if isRunning {
            start()
        }
    }

    // MARK: - System Audio Switching
    
    /// Switch system audio output to the selected input device (e.g., BlackHole)
    private func switchSystemAudioToInputDevice() {
        let deviceManager = AudioDeviceManager.shared
        
        // Save current system output before switching
        deviceManager.saveCurrentOutputDevice()
        
        // VOLUME SYNC: Get current system output volume before switching
        var currentVolume: Float? = nil
        if let currentOutput = deviceManager.getSystemDefaultOutputDevice() {
            currentVolume = deviceManager.getDeviceVolume(currentOutput)
            if let volume = currentVolume {
                Logger.log("[AudioGraph] Current system volume: \(Int(volume * 100))%")
            }
        }
        
        // Use the selected input device, or fall back to any BlackHole device
        guard let inputDevice = selectedInputDevice?.device ?? deviceManager.findBlackHoleDevice() else {
            Logger.log("[AudioGraph] Warning: No input device selected and no BlackHole device found for system audio switching")
            return
        }
        
        // VOLUME SYNC: Set volume on target input device BEFORE switching to it
        if let volume = currentVolume {
            let volumeSet = deviceManager.setDeviceVolume(inputDevice, volume: volume)
            if volumeSet {
                Logger.log("[AudioGraph] 🔊 Volume matched to current level (\(Int(volume * 100))%) on input device")
            }
        }
        
        // Switch to the input device FIRST (before setting physical device to 100%)
        let success = deviceManager.setSystemDefaultOutputDevice(inputDevice)
        if success {
            Logger.log("[AudioGraph] System audio output switched to: \(inputDevice.name)")
        } else {
            Logger.log("[AudioGraph] Failed to switch system audio output to: \(inputDevice.name)")
        }
        
        // NOW gradually ramp up selected output device to 100% (safe - system is on input device)
        if let selectedOutput = selectedOutputDevice {
            // Get current volume
            let currentVolume = deviceManager.getDeviceVolume(selectedOutput.device) ?? 0.5
            
            // Delay before starting ramp (give system time to fully switch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                
                // Gradual ramp from current to 100% over 0.5 seconds
                self.rampVolume(
                    device: selectedOutput.device,
                    from: currentVolume,
                    to: 1.0,
                    duration: 0.5,
                    deviceName: selectedOutput.name
                )
            }
        }
    }
    
    /// Gradually ramp device volume from one level to another
    private func rampVolume(device: AudioDevice, from startVolume: Float, to endVolume: Float, duration: TimeInterval, deviceName: String) {
        let steps = 20 // Number of volume steps
        let stepDuration = duration / Double(steps)
        let volumeIncrement = (endVolume - startVolume) / Float(steps)
        
        let deviceManager = AudioDeviceManager.shared
        
        for step in 0...steps {
            let delay = stepDuration * Double(step)
            let targetVolume = startVolume + (volumeIncrement * Float(step))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = deviceManager.setDeviceVolume(device, volume: targetVolume)
                
                // Log completion
                if step == steps {
                    Logger.log("[AudioGraph] 🔊 Ramped \(deviceName) to 100% for BlackHole volume control")
                }
            }
        }
    }
    
    /// Restore system audio output to user's selected device
    private func restoreSystemAudioToSelected() {
        let deviceManager = AudioDeviceManager.shared
        
        // SAFETY: Get current system volume (BlackHole) before switching
        var currentVolume: Float? = nil
        if let currentOutput = deviceManager.getSystemDefaultOutputDevice() {
            currentVolume = deviceManager.getDeviceVolume(currentOutput)
            if let volume = currentVolume {
                Logger.log("[AudioGraph] Current system volume: \(Int(volume * 100))%")
            }
        }
        
        // Try to use the selected output device from settings
        if let selectedOutput = selectedOutputDevice {
            // SAFETY: Set volume on target device BEFORE switching to it
            if let volume = currentVolume {
                let volumeSet = deviceManager.setDeviceVolume(selectedOutput.device, volume: volume)
                if volumeSet {
                    Logger.log("[AudioGraph] 🔊 Volume matched to BlackHole level for safety")
                } else {
                    Logger.log("[AudioGraph] ⚠️ Could not set volume on output device")
                }
            }
            
            let success = deviceManager.setSystemDefaultOutputDevice(selectedOutput.device)
            if success {
                Logger.log("[AudioGraph] System audio output restored to: \(selectedOutput.name)")
                return
            }
        }
        
        // Fallback: try to restore from saved device
        let restored = deviceManager.restoreSavedOutputDevice()
        if restored {
            Logger.log("[AudioGraph] System audio output restored from saved preference")
            
            // Try to apply volume to restored device as well
            if let volume = currentVolume,
               let restoredDevice = deviceManager.getSystemDefaultOutputDevice() {
                _ = deviceManager.setDeviceVolume(restoredDevice, volume: volume)
            }
        } else {
            Logger.log("[AudioGraph] Could not restore system audio output")
        }
    }
    
    // MARK: - Private Setup Methods

    private func setupAudioUnit(device: AudioDevice, outputChannelRange: Range<Int>?) throws {
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioError.instantiationFailed(status)
        }

        // Ensure cleanup on error
        defer {
            if self.audioUnit == nil {
                // Setup failed, clean up temporary unit
                AudioComponentInstanceDispose(audioUnit)
            }
        }

        // Enable IO for both Input (Element 1) and Output (Element 0)
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // Input Element
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to enable input on element 1")
        }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // Output Element
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to enable output on element 0")
        }

        // Set the Current Device
        var deviceID = device.id
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioError.deviceSetFailed(status)
        }

        // Get Device Format to determine sample rate and channel counts
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        // Check Input Scope of Element 1 (Device Input)
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &size
        )
        guard status == noErr else {
            throw AudioError.formatGetFailed(status)
        }

        currentSampleRate = deviceFormat.mSampleRate
        inputChannelCount = deviceFormat.mChannelsPerFrame
        
        // Check Output Scope of Element 0 (Device Output)
        // We need to know the output channel count to map our stereo output correctly
        var outputDeviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &outputDeviceFormat,
            &size
        )
        outputChannelCount = outputDeviceFormat.mChannelsPerFrame
        
        Logger.log("[AudioGraph] Aggregate Device: \(device.name)")
        Logger.log("  Input Channels: \(inputChannelCount)")
        Logger.log("  Output Channels: \(outputChannelCount)")
        Logger.log("  Sample Rate: \(currentSampleRate)")

        // Set Stream Format for Input (Element 1 Output Scope)
        // This is the format we want the AU to provide data TO us
        var inputStreamFormat = AudioStreamBasicDescription(
            mSampleRate: currentSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: inputChannelCount, // Match device input channels
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &inputStreamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        // Set Stream Format for Output (Element 0 Input Scope)
        // This is the format we will provide data FROM
        // We will provide stereo (or match output channels if we want to map directly)
        // But our HRIR engine produces stereo. We'll map that to the first 2 channels of the output.
        // To keep it simple, we tell the AU we are providing the same number of channels as the device expects,
        // but we'll only fill the first 2.
        
        var outputStreamFormat = AudioStreamBasicDescription(
            mSampleRate: currentSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: outputChannelCount, // Match device output channels
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &outputStreamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        // Set Render Callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callback = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: selfPtr
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioError.callbackSetFailed(status)
        }

        // Initialize
        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw AudioError.initializationFailed(status, "Aggregate Audio Unit")
        }

        self.audioUnit = audioUnit
    }
}

// MARK: - Audio Callback

/// Single render callback for pass-through processing
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let manager = Unmanaged<AudioGraphManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let audioUnit = manager.audioUnit,
          let ioData = ioData,
          let inputBufferListPtr = manager.inputAudioBufferListPtr else {
        return noErr
    }

    let frameCount = Int(inNumberFrames)
    
    // 1. Pull Input Data from Element 1
    // ---------------------------------
    
    // Configure the pre-allocated AudioBufferList for input
    let inputBufferList = inputBufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
    let inputChannelCount = Int(manager.inputChannelCount)
    
    // Safety check - clamp channel count to prevent buffer overflow
    // This can happen during startup or device changes
    if inputChannelCount > manager.maxChannels || inputChannelCount == 0 {
        // Zero output and return silently
        let outputChannelCount = Int(ioData.pointee.mNumberBuffers)
        withUnsafeMutablePointer(to: &ioData.pointee.mBuffers) { buffersPtr in
            let bufferPtr = UnsafeMutableRawPointer(buffersPtr).assumingMemoryBound(to: AudioBuffer.self)
            for i in 0..<outputChannelCount {
                let buffer = bufferPtr.advanced(by: i)
                if let data = buffer.pointee.mData {
                    memset(data, 0, frameCount * MemoryLayout<Float>.size)
                }
            }
        }
        return noErr
    }
    
    #if DEBUG
    if frameCount > manager.maxFramesPerCallback {
         assertionFailure("CoreAudio contract violation: frameCount=\(frameCount)")
         return kAudioUnitErr_TooManyFramesToProcess
    }
    #endif
    
    inputBufferList.pointee.mNumberBuffers = UInt32(inputChannelCount)
    
    if let inputBuffers = manager.inputAudioBuffersPtr {
        withUnsafeMutablePointer(to: &inputBufferList.pointee.mBuffers) { buffersPtr in
            let bufferPtr = UnsafeMutableRawPointer(buffersPtr).assumingMemoryBound(to: AudioBuffer.self)
            for i in 0..<inputChannelCount {
                let buffer = bufferPtr.advanced(by: i)
                buffer.pointee.mNumberChannels = 1
                buffer.pointee.mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                buffer.pointee.mData = inputBuffers[i]
            }
        }
    }
    
    var actionFlags: AudioUnitRenderActionFlags = []
    
    let status = AudioUnitRender(
        audioUnit,
        &actionFlags,
        inTimeStamp,
        1, // Input Element
        inNumberFrames,
        inputBufferList
    )
    
    if status != noErr {
        return status
    }
    
    // 2. Process Audio (Convolution)
    // ------------------------------
    
    // Map input buffers to Float pointers
    if let inputBuffers = manager.inputAudioBuffersPtr,
       let channelPtrs = manager.inputChannelBufferPtrs {
        for i in 0..<inputChannelCount {
            // Cast raw void* to Float*
            let floatPtr = inputBuffers[i].assumingMemoryBound(to: Float.self)
            channelPtrs[i] = floatPtr
        }
    }
    
    // Determine which input channels to use (selected range from input device)
    let inputRange = manager.selectedInputChannelRange ?? 0..<min(2, inputChannelCount)
    let leftInputChannel = inputRange.lowerBound
    let rightInputChannel = min(leftInputChannel + 1, inputRange.upperBound - 1)

    let shouldProcess = manager.hrirManager?.isConvolutionActive ?? false

    if shouldProcess, let channelPtrs = manager.inputChannelBufferPtrs {
        // Feed every channel in the selected range so multi-channel presets
        // (5.1/7.1) can drive more than just the first two speakers
        let channelCount = max(0, min(inputRange.count, inputChannelCount - leftInputChannel))

        manager.hrirManager?.processAudio(
            inputPtrs: channelPtrs.advanced(by: leftInputChannel),
            inputCount: channelCount,
            leftOutput: manager.outputStereoLeftPtr,
            rightOutput: manager.outputStereoRightPtr,
            frameCount: frameCount
        )
    } else {
        // Passthrough / Mixdown - use selected input channels
        let byteSize = frameCount * MemoryLayout<Float>.size
        memset(manager.outputStereoLeftPtr, 0, byteSize)
        memset(manager.outputStereoRightPtr, 0, byteSize)
        
        if inputChannelCount > 0, let channelPtrs = manager.inputChannelBufferPtrs {
            // Use left channel from selected input device
            if leftInputChannel < inputChannelCount {
                let src = channelPtrs[leftInputChannel]
                memcpy(manager.outputStereoLeftPtr, src, byteSize)
            }
            
            // Use right channel from selected input device
            if rightInputChannel < inputChannelCount {
                let src2 = channelPtrs[rightInputChannel]
                memcpy(manager.outputStereoRightPtr, src2, byteSize)
            } else if leftInputChannel < inputChannelCount {
                // Mono input - copy left to right
                let src = channelPtrs[leftInputChannel]
                memcpy(manager.outputStereoRightPtr, src, byteSize)
            }
        }
    }
    
    // 3. Write Output Data to Element 0
    // ---------------------------------
    
    let outputChannelCount = Int(ioData.pointee.mNumberBuffers)
    
    withUnsafeMutablePointer(to: &ioData.pointee.mBuffers) { buffersPtr in
        let bufferPtr = UnsafeMutableRawPointer(buffersPtr).assumingMemoryBound(to: AudioBuffer.self)
        
        // Zero ALL output channels first
        for i in 0..<outputChannelCount {
            let buffer = bufferPtr.advanced(by: i)
            if let data = buffer.pointee.mData {
                 memset(data, 0, frameCount * MemoryLayout<Float>.size)
            }
        }
        
        // Write stereo output to SELECTED channels only
        if let channelRange = manager.selectedOutputChannelRange {
            #if DEBUG
            assert(channelRange.upperBound <= outputChannelCount, "Channel range validation failed!")
            #endif
            
            let leftChannel = channelRange.lowerBound
            let rightChannel = leftChannel + 1
            
            if rightChannel < outputChannelCount {
                let leftBuffer = bufferPtr.advanced(by: leftChannel)
                let rightBuffer = bufferPtr.advanced(by: rightChannel)
                
                if let leftData = leftBuffer.pointee.mData,
                   let rightData = rightBuffer.pointee.mData {
                    memcpy(leftData, manager.outputStereoLeftPtr, frameCount * MemoryLayout<Float>.size)
                    memcpy(rightData, manager.outputStereoRightPtr, frameCount * MemoryLayout<Float>.size)
                }
            }
        }
    }

    return noErr
}

// MARK: - Error Types

enum AudioError: LocalizedError {
    case componentNotFound
    case instantiationFailed(OSStatus)
    case propertySetFailed(OSStatus, String)
    case deviceSetFailed(OSStatus)
    case deviceNotFound(String)
    case formatGetFailed(OSStatus)
    case formatSetFailed(OSStatus)
    case callbackSetFailed(OSStatus)
    case initializationFailed(OSStatus, String)
    case startFailed(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .componentNotFound:
            return "Audio component not found"
        case .instantiationFailed(let status):
            return "Failed to instantiate audio unit (error \(status))"
        case .propertySetFailed(let status, let detail):
            return "Failed to set property: \(detail) (error \(status))"
        case .deviceSetFailed(let status):
            return "Failed to set device (error \(status))"
        case .deviceNotFound(let deviceName):
            return "Device '\(deviceName)' is no longer available"
        case .formatGetFailed(let status):
            return "Failed to get audio format (error \(status))"
        case .formatSetFailed(let status):
            return "Failed to set audio format (error \(status))"
        case .callbackSetFailed(let status):
            return "Failed to set audio callback (error \(status))"
        case .initializationFailed(let status, let unit):
            return "Failed to initialize \(unit) (error \(status))"
        case .startFailed(let status, let detail):
            return "Failed to start: \(detail) (error \(status))"
        }
    }
}
