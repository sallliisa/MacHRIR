//
//  AudioGraphManager.swift
//  MacHRIR
//
//  Manages CoreAudio graph with multi-channel input support
//

import Foundation
import CoreAudio
import AVFoundation
import Combine
import Accelerate

/// Manages audio input/output using separate CoreAudio units with multi-channel support
class AudioGraphManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var inputDevice: AudioDevice?
    @Published var outputDevice: AudioDevice?
    @Published var errorMessage: String?
    // MARK: - Private Properties

    fileprivate var inputUnit: AudioUnit?
    fileprivate var outputUnit: AudioUnit?
    fileprivate let circularBuffer: CircularBuffer
    private let bufferSize: Int = 65536

    fileprivate var inputChannelCount: UInt32 = 2
    fileprivate var outputChannelCount: UInt32 = 2
    fileprivate var currentSampleRate: Double = 48000.0

    // Pre-allocated buffers for multi-channel processing
    fileprivate var inputInterleaveBuffer: [Float] = []
    fileprivate var outputInterleaveBuffer: [Float] = []
    fileprivate let maxFramesPerCallback: Int = 4096
    fileprivate let maxChannels: Int = 16  // Support up to 16 channels
    
    // Buffering state
    fileprivate var isBuffering: Bool = true

    // Multi-channel buffers (one per channel)
    fileprivate var inputChannelBuffers: [[Float]] = []
    fileprivate var outputStereoLeft: [Float] = []
    fileprivate var outputStereoRight: [Float] = []
    
    // Pre-allocated AudioBufferList for Input Callback
    fileprivate var inputAudioBufferListPtr: UnsafeMutableRawPointer?
    fileprivate var inputAudioBuffersPtr: [UnsafeMutableRawPointer] = []

    // Reference to HRIR manager for convolution
    var hrirManager: HRIRManager?

    // MARK: - Initialization

    init() {
        self.circularBuffer = CircularBuffer(size: bufferSize)

        // Pre-allocate interleave buffers (max channels at max frame count)
        self.inputInterleaveBuffer = [Float](repeating: 0, count: maxFramesPerCallback * maxChannels)
        self.outputInterleaveBuffer = [Float](repeating: 0, count: maxFramesPerCallback * maxChannels)

        // Pre-allocate per-channel buffers
        for _ in 0..<maxChannels {
            inputChannelBuffers.append([Float](repeating: 0, count: maxFramesPerCallback))
        }
        
        outputStereoLeft = [Float](repeating: 0, count: maxFramesPerCallback)
        outputStereoRight = [Float](repeating: 0, count: maxFramesPerCallback)
    }

    deinit {
        stop()
        deallocateInputBuffers()
    }

    // MARK: - Public Methods

    /// Start the audio engine with selected devices
    func start() {
        guard let inputDevice = inputDevice, let outputDevice = outputDevice else {
            errorMessage = "Please select both input and output devices"
            return
        }
        
        // Validate that devices still exist in the system
        let allDevices = AudioDeviceManager.getAllDevices()
        guard allDevices.contains(where: { $0.id == inputDevice.id }) else {
            errorMessage = "Input device '\(inputDevice.name)' is no longer available"
            return
        }
        guard allDevices.contains(where: { $0.id == outputDevice.id }) else {
            errorMessage = "Output device '\(outputDevice.name)' is no longer available"
            return
        }

        stop()

        do {
            try setupInputUnit(device: inputDevice)
            try setupOutputUnit(device: outputDevice)

            // Notify HRIR manager of the input layout
            if let hrirManager = hrirManager, let activePreset = hrirManager.activePreset {
                let inputLayout = InputLayout.detect(channelCount: Int(inputChannelCount))
                hrirManager.activatePreset(
                    activePreset,
                    targetSampleRate: currentSampleRate,
                    inputLayout: inputLayout
                )
            }

            circularBuffer.reset()

            var status = AudioOutputUnitStart(inputUnit!)
            guard status == noErr else {
                throw AudioError.startFailed(status, "Failed to start input unit")
            }

            status = AudioOutputUnitStart(outputUnit!)
            guard status == noErr else {
                throw AudioError.startFailed(status, "Failed to start output unit")
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
        if let input = inputUnit {
            AudioOutputUnitStop(input)
            AudioUnitUninitialize(input)
            AudioComponentInstanceDispose(input)
            inputUnit = nil
        }

        if let output = outputUnit {
            AudioOutputUnitStop(output)
            AudioUnitUninitialize(output)
            AudioComponentInstanceDispose(output)
            outputUnit = nil
        }

        circularBuffer.reset()

        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    /// Select input device
    func selectInputDevice(_ device: AudioDevice) {
        inputDevice = device
        if isRunning {
            start()
        }
    }

    /// Select output device
    func selectOutputDevice(_ device: AudioDevice) {
        outputDevice = device
        if isRunning {
            start()
        }
    }
    
    // MARK: - Buffer Management
    
    private func allocateInputBuffers(channelCount: Int, maxFrames: Int) {
        deallocateInputBuffers()
        
        let bytesPerChannel = maxFrames * MemoryLayout<Float>.size
        
        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        inputAudioBufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        
        let abl = inputAudioBufferListPtr!.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(channelCount)
        
        for _ in 0..<channelCount {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerChannel, alignment: 16)
            inputAudioBuffersPtr.append(buffer)
        }
        
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for (i, buffer) in inputAudioBuffersPtr.enumerated() {
            buffers[i].mNumberChannels = 1
            buffers[i].mDataByteSize = UInt32(bytesPerChannel)
            buffers[i].mData = buffer
        }
    }
    
    private func deallocateInputBuffers() {
        if let ptr = inputAudioBufferListPtr {
            ptr.deallocate()
            inputAudioBufferListPtr = nil
        }
        
        for buffer in inputAudioBuffersPtr {
            buffer.deallocate()
        }
        inputAudioBuffersPtr.removeAll()
    }

    // MARK: - Private Setup Methods

    private func setupInputUnit(device: AudioDevice) throws {
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
        guard status == noErr, let inputUnit = unit else {
            throw AudioError.instantiationFailed(status)
        }

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to enable input")
        }

        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to disable output")
        }

        var deviceID = device.id
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioError.deviceSetFailed(status)
        }

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &size
        )
        guard status == noErr else {
            throw AudioError.formatGetFailed(status)
        }

        inputChannelCount = deviceFormat.mChannelsPerFrame
        currentSampleRate = deviceFormat.mSampleRate
        
        print("[AudioGraph] Input device: \(device.name), Channels: \(inputChannelCount), Sample Rate: \(currentSampleRate)")
        
        allocateInputBuffers(channelCount: Int(inputChannelCount), maxFrames: maxFramesPerCallback)

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                          kAudioFormatFlagIsPacked |
                          kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callback = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: selfPtr
        )

        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioError.callbackSetFailed(status)
        }

        status = AudioUnitInitialize(inputUnit)
        guard status == noErr else {
            throw AudioError.initializationFailed(status, "Input unit")
        }

        self.inputUnit = inputUnit
    }

    private func setupOutputUnit(device: AudioDevice) throws {
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
        guard status == noErr, let outputUnit = unit else {
            throw AudioError.instantiationFailed(status)
        }

        var deviceID = device.id
        status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioError.deviceSetFailed(status)
        }

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            outputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &deviceFormat,
            &size
        )
        guard status == noErr else {
            throw AudioError.formatGetFailed(status)
        }

        outputChannelCount = deviceFormat.mChannelsPerFrame

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                          kAudioFormatFlagIsPacked |
                          kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            outputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callback = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: selfPtr
        )

        status = AudioUnitSetProperty(
            outputUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioError.callbackSetFailed(status)
        }

        status = AudioUnitInitialize(outputUnit)
        guard status == noErr else {
            throw AudioError.initializationFailed(status, "Output unit")
        }

        self.outputUnit = outputUnit
    }
}

// MARK: - Audio Callbacks

/// Input callback - pulls audio from input device and writes to circular buffer
private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let manager = Unmanaged<AudioGraphManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let inputUnit = manager.inputUnit else { return noErr }
    
    guard let audioBufferListPtr = manager.inputAudioBufferListPtr else { return noErr }
    let audioBufferList = audioBufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
    
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let bytesPerChannel = Int(inNumberFrames) * 4
    for i in 0..<buffers.count {
        buffers[i].mDataByteSize = UInt32(bytesPerChannel)
    }

    let status = AudioUnitRender(
        inputUnit,
        ioActionFlags,
        inTimeStamp,
        1,
        inNumberFrames,
        audioBufferList
    )

    if status == noErr {
        let frameCount = Int(inNumberFrames)
        let channelCount = buffers.count
        let totalSamples = frameCount * channelCount

        // Interleave
        manager.inputInterleaveBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            
            for channel in 0..<channelCount {
                if let data = buffers[channel].mData {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    // Copy with stride to interleave
                    // vDSP_vsmul with 1.0 is just a copy, but vDSP_mmov is better or just a loop?
                    // Actually, to interleave:
                    // dst[i * stride + channel] = src[i]
                    // vDSP can do this with stride.
                    
                    // Using vDSP_mmov (memory move) or vDSP_vadd with 0?
                    // vDSP_vsmul with 1.0 is fine for strided copy if we want to be "DSP-ish",
                    // but let's just use what was there but cleaner if possible.
                    // The original code used vDSP_vsmul to copy to interleaved buffer.
                    // We can keep it or simplify. Let's keep the logic but remove the explicit "1.0" variable if not needed,
                    // or just keep it as is for the copy-to-interleaved step since it works.
                    // Wait, the user complained about "messy" audio. Redundant math might add noise? Unlikely with 1.0.
                    // But let's optimize.
                    
                    var one: Float = 1.0
                    vDSP_vsmul(samples, 1, &one, baseAddr.advanced(by: channel), vDSP_Stride(channelCount), vDSP_Length(frameCount))
                }
            }
        }

        manager.inputInterleaveBuffer.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                manager.circularBuffer.write(data: baseAddress, size: totalSamples * 4)
            }
        }
    }

    return noErr
}

/// Output callback - reads from circular buffer and provides to output device
private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let manager = Unmanaged<AudioGraphManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let bufferList = ioData else { return noErr }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let outputChannelCount = Int(bufferList.pointee.mNumberBuffers)
    let frameCount = Int(inNumberFrames)

    // Read interleaved data from circular buffer
    let inputChannelCount = Int(manager.inputChannelCount)
    let totalSamples = frameCount * inputChannelCount
    let totalBytes = totalSamples * 4
    
    // Buffering Logic
    let playbackThreshold = 2048 * inputChannelCount * 4 // e.g. 2048 frames
    
    if manager.isBuffering {
        if manager.circularBuffer.availableReadSpace() >= playbackThreshold {
            manager.isBuffering = false
            // print("Buffering complete, resuming playback")
        } else {
            // Output silence
            for i in 0..<buffers.count {
                if let data = buffers[i].mData {
                    memset(data, 0, Int(buffers[i].mDataByteSize))
                }
            }
            return noErr
        }
    }

    let bytesRead = manager.outputInterleaveBuffer.withUnsafeMutableBytes { ptr in
        manager.circularBuffer.read(into: ptr.baseAddress!, size: totalBytes)
    }

    if bytesRead < totalBytes {
        // Underrun detected
        // print("Underrun detected, switching to buffering")
        manager.isBuffering = true
        
        // Fill the rest with silence
        let samplesRead = bytesRead / 4
        for i in samplesRead..<totalSamples {
            manager.outputInterleaveBuffer[i] = 0.0
        }
    }

    // De-interleave into per-channel buffers
    for channel in 0..<min(inputChannelCount, manager.maxChannels) {
        manager.outputInterleaveBuffer.withUnsafeBufferPointer { srcPtr in
            guard let srcBase = srcPtr.baseAddress else { return }
            
            // Just copy, no multiply
            manager.inputChannelBuffers[channel].withUnsafeMutableBufferPointer { dstPtr in
                if let dstBase = dstPtr.baseAddress {
                    // Strided copy from interleaved to planar
                    // vDSP_mmovD is for doubles.
                    // Use vDSP_vadd with zero or just a loop?
                    // vDSP_vsmul with 1.0 is standard for strided copy.
                    var one: Float = 1.0
                    vDSP_vsmul(srcBase.advanced(by: channel), vDSP_Stride(inputChannelCount), &one, dstBase, 1, vDSP_Length(frameCount))
                }
            }
        }
    }

    // Process through HRIR convolution if enabled
    let shouldProcess = manager.hrirManager?.convolutionEnabled ?? false

    if shouldProcess {
        // Pass all input channels to HRIR manager
        let inputChannels = Array(manager.inputChannelBuffers.prefix(inputChannelCount))
        manager.hrirManager?.processAudio(
            inputs: inputChannels,
            leftOutput: &manager.outputStereoLeft,
            rightOutput: &manager.outputStereoRight,
            frameCount: frameCount
        )
    } else {
        // Passthrough: simple stereo downmix
        let byteCount = frameCount * MemoryLayout<Float>.size
        if inputChannelCount >= 1 {
            _ = manager.outputStereoLeft.withUnsafeMutableBytes { dst in
                manager.inputChannelBuffers[0].withUnsafeBytes { src in
                    memcpy(dst.baseAddress!, src.baseAddress!, byteCount)
                }
            }
        }
        if inputChannelCount >= 2 {
            _ = manager.outputStereoRight.withUnsafeMutableBytes { dst in
                manager.inputChannelBuffers[1].withUnsafeBytes { src in
                    memcpy(dst.baseAddress!, src.baseAddress!, byteCount)
                }
            }
        }
    }

    // Write processed audio to output buffers
    for i in 0..<min(outputChannelCount, 2) {
        if let data = buffers[i].mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let sourceBuffer = (i == 0) ? manager.outputStereoLeft : manager.outputStereoRight
            
            let byteCount = frameCount * MemoryLayout<Float>.size
            _ = sourceBuffer.withUnsafeBytes { src in
                memcpy(samples, src.baseAddress!, byteCount)
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
