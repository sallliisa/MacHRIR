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

    fileprivate let maxFramesPerCallback: Int = 4096
    fileprivate let maxChannels: Int = 16  // Support up to 16 channels
    
    // Buffering state
    fileprivate var isBuffering: Bool = true

    // Multi-channel buffers using UnsafeMutablePointer for zero-allocation real-time processing
    // We use UnsafeMutablePointer<UnsafeMutablePointer<Float>> to avoid Swift Array overhead in callbacks
    fileprivate var inputChannelBufferPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    fileprivate var outputStereoLeftPtr: UnsafeMutablePointer<Float>!
    fileprivate var outputStereoRightPtr: UnsafeMutablePointer<Float>!
    
    // Pre-allocated AudioBufferList for Input Callback
    fileprivate var inputAudioBufferListPtr: UnsafeMutableRawPointer?
    // Array of pointers to raw audio buffers (UnsafeMutablePointer<UnsafeMutableRawPointer>)
    fileprivate var inputAudioBuffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>?

    // Reference to HRIR manager for convolution
    var hrirManager: HRIRManager?

    // MARK: - Initialization

    init() {
        self.circularBuffer = CircularBuffer(size: bufferSize)

        // Pre-allocate AudioBufferList for input callback
        let bufferListSize = MemoryLayout<AudioBufferList>.size +
                             max(0, maxChannels - 1) * MemoryLayout<AudioBuffer>.size
        
        inputAudioBufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        
        // Pre-allocate per-channel audio data buffers (raw bytes for AudioUnit)
        // Allocate the array of pointers first
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

        // Pre-allocate per-channel buffers using UnsafeMutablePointer
        // Allocate the array of pointers first
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
    
    let channelCount = Int(manager.inputChannelCount)
    let frameCount = Int(inNumberFrames)
    let bytesPerChannel = frameCount * MemoryLayout<Float>.size
    
    // Validate we don't exceed pre-allocated size
    guard frameCount <= manager.maxFramesPerCallback,
          channelCount <= manager.maxChannels else {
        return kAudioUnitErr_TooManyFramesToProcess
    }
    
    // Configure the pre-allocated AudioBufferList
    let audioBufferList = audioBufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
    audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)
    
    // Configure each buffer to point to our pre-allocated memory
    // Use withUnsafeMutablePointer to avoid dangling pointer warning
    if let inputBuffers = manager.inputAudioBuffersPtr {
        withUnsafeMutablePointer(to: &audioBufferList.pointee.mBuffers) { buffersPtr in
            let bufferPtr = UnsafeMutableRawPointer(buffersPtr)
                .assumingMemoryBound(to: AudioBuffer.self)
            
            for i in 0..<channelCount {
                let buffer = bufferPtr.advanced(by: i)
                buffer.pointee.mNumberChannels = 1
                buffer.pointee.mDataByteSize = UInt32(bytesPerChannel)
                buffer.pointee.mData = inputBuffers[i]
            }
        }
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
        // Write sequentially to circular buffer (no interleaving)
        // This avoids the need for an intermediate interleave buffer and vDSP calls
        // Write sequentially to circular buffer (no interleaving)
        if let inputBuffers = manager.inputAudioBuffersPtr {
            for i in 0..<channelCount {
                manager.circularBuffer.write(
                    data: inputBuffers[i],
                    size: bytesPerChannel
                )
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

    let outputChannelCount = Int(bufferList.pointee.mNumberBuffers)
    let frameCount = Int(inNumberFrames)

    // Use withUnsafeMutablePointer to avoid dangling pointer warning
    // Wrap all buffer access in this scope
    withUnsafeMutablePointer(to: &bufferList.pointee.mBuffers) { buffersPtr in
        let bufferPtr = UnsafeMutableRawPointer(buffersPtr)
            .assumingMemoryBound(to: AudioBuffer.self)
        
        // Validate frame count
        guard frameCount <= manager.maxFramesPerCallback else {
            // Fill with silence and return
            for i in 0..<outputChannelCount {
                let buffer = bufferPtr.advanced(by: i)
                if let data = buffer.pointee.mData {
                    memset(data, 0, Int(buffer.pointee.mDataByteSize))
                }
            }
            return
        }

        let inputChannelCount = Int(manager.inputChannelCount)
        let totalBytesNeeded = frameCount * inputChannelCount * 4
        
        // Buffering Logic
        let playbackThreshold = 512 * inputChannelCount * 4
        
        if manager.isBuffering {
            if manager.circularBuffer.availableReadSpace() >= playbackThreshold {
                manager.isBuffering = false
            } else {
                // Output silence
                for i in 0..<outputChannelCount {
                    let buffer = bufferPtr.advanced(by: i)
                    if let data = buffer.pointee.mData {
                        memset(data, 0, Int(buffer.pointee.mDataByteSize))
                    }
                }
                return
            }
        }

        // Check for underrun
        if manager.circularBuffer.availableReadSpace() < totalBytesNeeded {
            manager.isBuffering = true
            // Output silence
            for i in 0..<outputChannelCount {
                let buffer = bufferPtr.advanced(by: i)
                if let data = buffer.pointee.mData {
                    memset(data, 0, Int(buffer.pointee.mDataByteSize))
                }
            }
            return
        }

        // Read sequential data from circular buffer into inputChannelBufferPtrs
        // This matches the sequential write in inputRenderCallback
        // Read sequential data from circular buffer into inputChannelBufferPtrs
        // This matches the sequential write in inputRenderCallback
        if let channelPtrs = manager.inputChannelBufferPtrs {
            for i in 0..<inputChannelCount {
                // Safety check for channel count
                if i < manager.maxChannels {
                    let dstPtr = channelPtrs[i]
                    let byteSize = frameCount * MemoryLayout<Float>.size
                    manager.circularBuffer.read(into: dstPtr, size: byteSize)
                }
            }
        }

        // Process through HRIR convolution if enabled
        let shouldProcess = manager.hrirManager?.isConvolutionActive ?? false

        if shouldProcess, let channelPtrs = manager.inputChannelBufferPtrs {
            // Pass input channel pointers to HRIR manager (zero-copy, zero-allocation)
            manager.hrirManager?.processAudio(
                inputPtrs: channelPtrs,
                inputCount: inputChannelCount,
                leftOutput: manager.outputStereoLeftPtr,
                rightOutput: manager.outputStereoRightPtr,
                frameCount: frameCount
            )
        } else {
            // PASSTHROUGH: Mix down to stereo
            // Input is already in inputChannelBufferPtrs (non-interleaved)
            
            // Reset output buffers
            memset(manager.outputStereoLeftPtr, 0, frameCount * 4)
            memset(manager.outputStereoRightPtr, 0, frameCount * 4)
            
            // Simple mix: Left = Ch1, Right = Ch2 (if exists)
            // Or mono: Left = Ch1, Right = Ch1
            
            if inputChannelCount > 0, let channelPtrs = manager.inputChannelBufferPtrs {
                let src = channelPtrs[0]
                memcpy(manager.outputStereoLeftPtr, src, frameCount * 4)
                
                if inputChannelCount >= 2 {
                    let src2 = channelPtrs[1]
                    memcpy(manager.outputStereoRightPtr, src2, frameCount * 4)
                } else {
                    // Mono -> Stereo
                    memcpy(manager.outputStereoRightPtr, src, frameCount * 4)
                }
            }
        }

        // Write processed audio to output buffers
        for i in 0..<min(outputChannelCount, 2) {
            let buffer = bufferPtr.advanced(by: i)
            if let data = buffer.pointee.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                let sourcePtr = (i == 0) ? manager.outputStereoLeftPtr : manager.outputStereoRightPtr
                
                let byteCount = frameCount * MemoryLayout<Float>.size
                memcpy(samples, sourcePtr, byteCount)
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
