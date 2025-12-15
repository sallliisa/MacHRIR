//
//  AudioGraphManager.swift
//  MacHRIR
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

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var aggregateDevice: AudioDevice?
    @Published var errorMessage: String?
    
    // MARK: - Private Properties

    fileprivate var audioUnit: AudioUnit?
    
    // Device properties
    fileprivate var inputChannelCount: UInt32 = 0
    fileprivate var outputChannelCount: UInt32 = 2
    
    // NEW: Track which output channels to use
    fileprivate var selectedOutputChannelRange: Range<Int>?
    
    fileprivate var currentSampleRate: Double = 48000.0

    // Pre-allocated buffers for multi-channel processing
    fileprivate let maxFramesPerCallback: Int = 4096
    fileprivate let maxChannels: Int = 16  // Support up to 16 channels
    
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
    func setOutputChannels(_ range: Range<Int>) {
        // Validate range against current output channel count
        guard range.upperBound <= Int(outputChannelCount) else {
            DispatchQueue.main.async {
                self.errorMessage = "Output channel range \(range) exceeds device channel count (\(self.outputChannelCount))"
            }
            return
        }
        
        // Thread-safe update of output channel range
        // No need to reinitialize audio unit!
        selectedOutputChannelRange = range
    }

    /// Select aggregate device
    func selectAggregateDevice(_ device: AudioDevice) {
        aggregateDevice = device
        if isRunning {
            start()
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
    
    // Safety check (Debug only for performance)
    #if DEBUG
    if frameCount > manager.maxFramesPerCallback || inputChannelCount > manager.maxChannels {
         assertionFailure("CoreAudio contract violation: frameCount=\(frameCount), channels=\(inputChannelCount)")
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
    
    let shouldProcess = manager.hrirManager?.isConvolutionActive ?? false
    
    if shouldProcess, let channelPtrs = manager.inputChannelBufferPtrs {
        manager.hrirManager?.processAudio(
            inputPtrs: channelPtrs,
            inputCount: inputChannelCount,
            leftOutput: manager.outputStereoLeftPtr,
            rightOutput: manager.outputStereoRightPtr,
            frameCount: frameCount
        )
    } else {
        // Passthrough / Mixdown
        let byteSize = frameCount * MemoryLayout<Float>.size
        memset(manager.outputStereoLeftPtr, 0, byteSize)
        memset(manager.outputStereoRightPtr, 0, byteSize)
        
        if inputChannelCount > 0, let channelPtrs = manager.inputChannelBufferPtrs {
            let src = channelPtrs[0]
            memcpy(manager.outputStereoLeftPtr, src, frameCount * MemoryLayout<Float>.size)
            
            if inputChannelCount >= 2 {
                let src2 = channelPtrs[1]
                memcpy(manager.outputStereoRightPtr, src2, frameCount * MemoryLayout<Float>.size)
            } else {
                memcpy(manager.outputStereoRightPtr, src, frameCount * MemoryLayout<Float>.size)
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
