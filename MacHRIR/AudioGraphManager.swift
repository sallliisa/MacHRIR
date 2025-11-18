//
//  AudioGraphManager.swift
//  MacHRIR
//
//  Manages CoreAudio graph with separate Input/Output Audio Units
//  CRITICAL: Uses CoreAudio directly, NOT AVAudioEngine (see PASSTHROUGH_SPEC.md)
//

import Foundation
import CoreAudio
import AVFoundation
import Combine

/// Manages audio input/output using separate CoreAudio units
class AudioGraphManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var inputDevice: AudioDevice?
    @Published var outputDevice: AudioDevice?
    @Published var errorMessage: String?
    @Published var inputLevel: Float = 0.0
    @Published var outputLevel: Float = 0.0

    // MARK: - Private Properties

    fileprivate var inputUnit: AudioUnit?
    fileprivate var outputUnit: AudioUnit?
    fileprivate let circularBuffer: CircularBuffer
    private let bufferSize: Int = 65536  // ~1.5 seconds at 48kHz stereo

    private var inputChannelCount: UInt32 = 2
    private var outputChannelCount: UInt32 = 2
    private var currentSampleRate: Double = 48000.0

    // Pre-allocated buffers for interleaving (avoid allocations in callbacks)
    fileprivate var inputInterleaveBuffer: [Float] = []
    fileprivate var outputInterleaveBuffer: [Float] = []
    fileprivate let maxFramesPerCallback: Int = 4096  // Max expected frame count

    // Buffers for per-channel processing
    fileprivate var leftChannelBuffer: [Float] = []
    fileprivate var rightChannelBuffer: [Float] = []
    fileprivate var leftProcessedBuffer: [Float] = []
    fileprivate var rightProcessedBuffer: [Float] = []

    // Reference to HRIR manager for convolution
    var hrirManager: HRIRManager?

    // MARK: - Initialization

    init() {
        self.circularBuffer = CircularBuffer(size: bufferSize)

        // Pre-allocate interleave buffers (stereo at max frame count)
        self.inputInterleaveBuffer = [Float](repeating: 0, count: maxFramesPerCallback * 2)
        self.outputInterleaveBuffer = [Float](repeating: 0, count: maxFramesPerCallback * 2)

        // Pre-allocate processing buffers
        self.leftChannelBuffer = [Float](repeating: 0, count: maxFramesPerCallback)
        self.rightChannelBuffer = [Float](repeating: 0, count: maxFramesPerCallback)
        self.leftProcessedBuffer = [Float](repeating: 0, count: maxFramesPerCallback)
        self.rightProcessedBuffer = [Float](repeating: 0, count: maxFramesPerCallback)
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start the audio engine with selected devices
    func start() {
        guard let inputDevice = inputDevice, let outputDevice = outputDevice else {
            errorMessage = "Please select both input and output devices"
            return
        }

        stop()  // Stop any existing units

        do {
            try setupInputUnit(device: inputDevice)
            try setupOutputUnit(device: outputDevice)

            // Reset buffer before starting
            circularBuffer.reset()

            // Start both units
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
            start()  // Restart with new device
        }
    }

    /// Select output device
    func selectOutputDevice(_ device: AudioDevice) {
        outputDevice = device
        if isRunning {
            start()  // Restart with new device
        }
    }

    // MARK: - Private Setup Methods

    private func setupInputUnit(device: AudioDevice) throws {
        // 1. Create component description
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // 2. Find and instantiate component
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let inputUnit = unit else {
            throw AudioError.instantiationFailed(status)
        }

        // 3. Enable input (element 1)
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,  // Input element
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to enable input")
        }

        // 4. Disable output (element 0)
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,  // Output element
            &disableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioError.propertySetFailed(status, "Failed to disable output")
        }

        // 5. Set device BEFORE format (CRITICAL)
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

        // 6. Get device's format
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,  // Input element
            &deviceFormat,
            &size
        )
        guard status == noErr else {
            throw AudioError.formatGetFailed(status)
        }

        inputChannelCount = deviceFormat.mChannelsPerFrame
        currentSampleRate = deviceFormat.mSampleRate

        // 7. Set stream format (non-interleaved)
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
            1,  // Input element (output of input scope)
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        // 8. Set input callback
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

        // 9. Initialize
        status = AudioUnitInitialize(inputUnit)
        guard status == noErr else {
            throw AudioError.initializationFailed(status, "Input unit")
        }

        self.inputUnit = inputUnit
    }

    private func setupOutputUnit(device: AudioDevice) throws {
        // 1. Create component description
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // 2. Find and instantiate component
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let outputUnit = unit else {
            throw AudioError.instantiationFailed(status)
        }

        // 3. Set device BEFORE format (CRITICAL)
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

        // 4. Get device format
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            outputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,  // Output element
            &deviceFormat,
            &size
        )
        guard status == noErr else {
            throw AudioError.formatGetFailed(status)
        }

        outputChannelCount = deviceFormat.mChannelsPerFrame

        // 5. Set stream format (non-interleaved)
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
            0,  // Output element (input to output scope)
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioError.formatSetFailed(status)
        }

        // 6. Set render callback
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

        // 7. Initialize
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

    // Get stream format to determine channel count
    var streamFormat = AudioStreamBasicDescription()
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    let formatStatus = AudioUnitGetProperty(
        inputUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &streamFormat,
        &propertySize
    )

    guard formatStatus == noErr else { return formatStatus }

    let channelCount = max(1, Int(streamFormat.mChannelsPerFrame))
    let bytesPerChannel = Int(inNumberFrames) * 4  // 4 bytes per Float32

    // Allocate AudioBufferList with proper size for variable-length array
    let bufferListSize = MemoryLayout<AudioBufferList>.size +
                         max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size

    let bufferListPointer = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }

    let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)

    // Allocate data buffers (one per channel for non-interleaved)
    var audioBuffers: [UnsafeMutableRawPointer] = []
    for _ in 0..<channelCount {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerChannel,
            alignment: 16
        )
        audioBuffers.append(buffer)
    }

    defer {
        for buffer in audioBuffers {
            buffer.deallocate()
        }
    }

    // Set up the AudioBuffer structures
    let audioBuffersPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for (index, buffer) in audioBuffers.enumerated() {
        audioBuffersPtr[index].mNumberChannels = 1  // Non-interleaved
        audioBuffersPtr[index].mDataByteSize = UInt32(bytesPerChannel)
        audioBuffersPtr[index].mData = buffer
    }

    // Pull audio from input device
    let status = AudioUnitRender(
        inputUnit,
        ioActionFlags,
        inTimeStamp,
        1,  // Input element
        inNumberFrames,
        audioBufferList
    )

    // Write to circular buffer and calculate level
    if status == noErr {
        var maxLevel: Float = 0.0

        // Interleave the channels and write to circular buffer
        // This ensures proper channel ordering for the output callback
        let frameCount = Int(inNumberFrames)
        let totalSamples = frameCount * channelCount

        // Use pre-allocated buffer (no heap allocation)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let samples = audioBuffers[channel].assumingMemoryBound(to: Float.self)
                let sample = samples[frame]
                manager.inputInterleaveBuffer[frame * channelCount + channel] = sample
                maxLevel = max(maxLevel, abs(sample))
            }
        }

        // Write interleaved data to circular buffer
        manager.inputInterleaveBuffer.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                manager.circularBuffer.write(data: baseAddress, size: totalSamples * 4)
            }
        }

        // Update input level (on main thread periodically)
        DispatchQueue.main.async {
            manager.inputLevel = maxLevel
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
    let channelCount = Int(bufferList.pointee.mNumberBuffers)
    let frameCount = Int(inNumberFrames)

    var maxLevel: Float = 0.0

    // Read interleaved data from circular buffer
    let totalSamples = frameCount * channelCount
    let totalBytes = totalSamples * 4

    let bytesRead = manager.outputInterleaveBuffer.withUnsafeMutableBytes { ptr in
        manager.circularBuffer.read(into: ptr.baseAddress!, size: totalBytes)
    }

    // Check if we got enough data
    if bytesRead < totalBytes {
        // Fill remaining with silence
        let samplesRead = bytesRead / 4
        for i in samplesRead..<totalSamples {
            manager.outputInterleaveBuffer[i] = 0.0
        }
    }

    // De-interleave into separate channel buffers
    for frame in 0..<frameCount {
        manager.leftChannelBuffer[frame] = manager.outputInterleaveBuffer[frame * channelCount]
        if channelCount > 1 {
            manager.rightChannelBuffer[frame] = manager.outputInterleaveBuffer[frame * channelCount + 1]
        } else {
            manager.rightChannelBuffer[frame] = manager.leftChannelBuffer[frame]
        }
    }

    // Process through HRIR convolution if enabled
    let shouldProcess = manager.hrirManager?.convolutionEnabled ?? false

    // Debug logging (once)
    struct CallbackLogger {
        static var hasLogged = false
    }
    if !CallbackLogger.hasLogged {
        print("[AudioCallback] Frame count: \(frameCount), Should process: \(shouldProcess)")
        CallbackLogger.hasLogged = true
    }

    if shouldProcess {
        // Ensure output buffers are properly sized
        if manager.leftProcessedBuffer.count < frameCount {
            manager.leftProcessedBuffer = [Float](repeating: 0, count: manager.maxFramesPerCallback)
            manager.rightProcessedBuffer = [Float](repeating: 0, count: manager.maxFramesPerCallback)
        }

        // Process audio - buffers are pre-allocated, just pass them
        manager.hrirManager?.processAudio(
            leftInput: manager.leftChannelBuffer,
            rightInput: manager.rightChannelBuffer,
            leftOutput: &manager.leftProcessedBuffer,
            rightOutput: &manager.rightProcessedBuffer,
            frameCount: frameCount
        )
    } else {
        // Passthrough mode - copy input to output
        for i in 0..<frameCount {
            manager.leftProcessedBuffer[i] = manager.leftChannelBuffer[i]
            manager.rightProcessedBuffer[i] = manager.rightChannelBuffer[i]
        }
    }

    // Write processed audio to output buffers
    for i in 0..<min(channelCount, 2) {
        if let data = buffers[i].mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let sourceBuffer = (i == 0) ? manager.leftProcessedBuffer : manager.rightProcessedBuffer
            for frame in 0..<frameCount {
                let sample = sourceBuffer[frame]
                samples[frame] = sample
                maxLevel = max(maxLevel, abs(sample))
            }
        }
    }

    // Update output level
    DispatchQueue.main.async {
        manager.outputLevel = maxLevel
    }

    return noErr
}

// MARK: - Error Types

enum AudioError: LocalizedError {
    case componentNotFound
    case instantiationFailed(OSStatus)
    case propertySetFailed(OSStatus, String)
    case deviceSetFailed(OSStatus)
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
