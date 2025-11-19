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
import Accelerate

/// Manages audio input/output using separate CoreAudio units
class AudioGraphManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var inputDevice: AudioDevice?
    @Published var outputDevice: AudioDevice?
    @Published var errorMessage: String?
    @Published var inputLevel: Float = 0.0
    @Published var outputLevel: Float = 0.0
    @Published var meteringEnabled: Bool = false // Disabled by default for debugging

    // MARK: - Private Properties

    fileprivate var inputUnit: AudioUnit?
    fileprivate var outputUnit: AudioUnit?
    fileprivate let circularBuffer: CircularBuffer
    private let bufferSize: Int = 65536  // ~1.5 seconds at 48kHz stereo

    private var inputChannelCount: UInt32 = 2
    private var outputChannelCount: UInt32 = 2
    private var currentSampleRate: Double = 48000.0
    
    // UI Update Throttling
    fileprivate var lastUIUpdateTime: Double = 0.0
    fileprivate let uiUpdateInterval: Double = 0.05 // Update UI every 50ms

    // Pre-allocated buffers for interleaving (avoid allocations in callbacks)
    fileprivate var inputInterleaveBuffer: [Float] = []
    fileprivate var outputInterleaveBuffer: [Float] = []
    fileprivate let maxFramesPerCallback: Int = 4096  // Max expected frame count

    // Buffers for per-channel processing
    fileprivate var leftChannelBuffer: [Float] = []
    fileprivate var rightChannelBuffer: [Float] = []
    fileprivate var leftProcessedBuffer: [Float] = []
    fileprivate var rightProcessedBuffer: [Float] = []
    
    // Pre-allocated AudioBufferList for Input Callback
    // We use UnsafeMutableRawPointer to hold the memory for the AudioBufferList + buffers
    fileprivate var inputAudioBufferListPtr: UnsafeMutableRawPointer?
    fileprivate var inputAudioBuffersPtr: [UnsafeMutableRawPointer] = []

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
        deallocateInputBuffers()
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
    
    // MARK: - Buffer Management
    
    private func allocateInputBuffers(channelCount: Int, maxFrames: Int) {
        deallocateInputBuffers()
        
        let bytesPerChannel = maxFrames * MemoryLayout<Float>.size
        
        // Allocate AudioBufferList memory
        // AudioBufferList = UInt32 mNumberBuffers + [AudioBuffer]
        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        inputAudioBufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        
        // Initialize AudioBufferList
        let abl = inputAudioBufferListPtr!.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(channelCount)
        
        // Allocate data buffers
        for _ in 0..<channelCount {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerChannel, alignment: 16)
            inputAudioBuffersPtr.append(buffer)
        }
        
        // Link buffers to AudioBufferList
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
        
        // Pre-allocate buffers for callback
        allocateInputBuffers(channelCount: Int(inputChannelCount), maxFrames: maxFramesPerCallback)

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
    
    // Use pre-allocated buffer list
    guard let audioBufferListPtr = manager.inputAudioBufferListPtr else { return noErr }
    let audioBufferList = audioBufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
    
    // Update data size for this specific callback
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let bytesPerChannel = Int(inNumberFrames) * 4
    for i in 0..<buffers.count {
        buffers[i].mDataByteSize = UInt32(bytesPerChannel)
    }

    // Check if we should update UI (throttled)
    let currentTime = CFAbsoluteTimeGetCurrent()
    let shouldUpdateUI = manager.meteringEnabled && (currentTime - manager.lastUIUpdateTime > manager.uiUpdateInterval)

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
        let channelCount = buffers.count
        let totalSamples = frameCount * channelCount

        // Use cblas_scopy for fast strided copy (Interleaving)
        for channel in 0..<channelCount {
            if let data = buffers[channel].mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                
                // Calculate max level for UI ONLY if needed
                if shouldUpdateUI {
                    var channelMax: Float = 0.0
                    vDSP_maxmgv(samples, 1, &channelMax, vDSP_Length(frameCount))
                    maxLevel = max(maxLevel, channelMax)
                }
                
                // Copy with stride
                // Source: samples (stride 1)
                // Dest: inputInterleaveBuffer starting at offset 'channel' (stride channelCount)
                manager.inputInterleaveBuffer.withUnsafeMutableBufferPointer { ptr in
                    if let baseAddr = ptr.baseAddress {
                        var one: Float = 1.0
                        vDSP_vsmul(samples, 1, &one, baseAddr.advanced(by: channel), vDSP_Stride(channelCount), vDSP_Length(frameCount))
                    }
                }
            }
        }

        // Write interleaved data to circular buffer
        manager.inputInterleaveBuffer.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                manager.circularBuffer.write(data: baseAddress, size: totalSamples * 4)
            }
        }

        // Update input level (throttled)
        if shouldUpdateUI {
            DispatchQueue.main.async {
                manager.inputLevel = maxLevel
            }
            // Note: We don't update lastUIUpdateTime here to avoid contention/confusion with output callback.
            // The output callback handles the time update, or we can just let them race loosely.
            // For better results, we can update it here too if we want independent throttling.
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

    // De-interleave into separate channel buffers using vDSP_vsmul (multiplication by 1.0 is a copy)
    // Left Channel (0)
    manager.outputInterleaveBuffer.withUnsafeBufferPointer { srcPtr in
        guard let srcBase = srcPtr.baseAddress else { return }
        
        var one: Float = 1.0
        
        // Left
        manager.leftChannelBuffer.withUnsafeMutableBufferPointer { dstPtr in
            if let dstBase = dstPtr.baseAddress {
                vDSP_vsmul(srcBase, vDSP_Stride(channelCount), &one, dstBase, 1, vDSP_Length(frameCount))
            }
        }
        
        // Right
        if channelCount > 1 {
            manager.rightChannelBuffer.withUnsafeMutableBufferPointer { dstPtr in
                if let dstBase = dstPtr.baseAddress {
                    vDSP_vsmul(srcBase.advanced(by: 1), vDSP_Stride(channelCount), &one, dstBase, 1, vDSP_Length(frameCount))
                }
            }
        } else {
            // Mono -> Stereo copy
            let byteCount = frameCount * MemoryLayout<Float>.size
            manager.rightChannelBuffer.withUnsafeMutableBytes { dst in
                manager.leftChannelBuffer.withUnsafeBytes { src in
                    memcpy(dst.baseAddress!, src.baseAddress!, byteCount)
                }
            }
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
        // Process audio - buffers are pre-allocated, just pass them
        manager.hrirManager?.processAudio(
            leftInput: manager.leftChannelBuffer,
            rightInput: manager.rightChannelBuffer,
            leftOutput: &manager.leftProcessedBuffer,
            rightOutput: &manager.rightProcessedBuffer,
            frameCount: frameCount
        )
    } else {
        // Passthrough mode - fast copy using memcpy
        let byteCount = frameCount * MemoryLayout<Float>.size
        manager.leftProcessedBuffer.withUnsafeMutableBytes { dst in
            manager.leftChannelBuffer.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!, byteCount)
            }
        }
        manager.rightProcessedBuffer.withUnsafeMutableBytes { dst in
            manager.rightChannelBuffer.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!, byteCount)
            }
        }
    }

    // Write processed audio to output buffers
    
    // Check if we should update UI (throttled)
    let currentTime = CFAbsoluteTimeGetCurrent()
    let shouldUpdateUI = manager.meteringEnabled && (currentTime - manager.lastUIUpdateTime > manager.uiUpdateInterval)
    
    for i in 0..<min(channelCount, 2) {
        if let data = buffers[i].mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let sourceBuffer = (i == 0) ? manager.leftProcessedBuffer : manager.rightProcessedBuffer
            
            // Copy to output buffer
            let byteCount = frameCount * MemoryLayout<Float>.size
            sourceBuffer.withUnsafeBytes { src in
                memcpy(samples, src.baseAddress!, byteCount)
            }
            
            // Calculate level for UI ONLY if needed
            if shouldUpdateUI {
                var channelMax: Float = 0.0
                vDSP_maxmgv(samples, 1, &channelMax, vDSP_Length(frameCount))
                maxLevel = max(maxLevel, channelMax)
            }
        }
    }

    // Update output level (throttled)
    if shouldUpdateUI {
        manager.lastUIUpdateTime = currentTime
        DispatchQueue.main.async {
            manager.outputLevel = maxLevel
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
