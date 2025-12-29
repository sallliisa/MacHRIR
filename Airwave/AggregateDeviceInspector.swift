import Foundation
import CoreAudio
import AudioToolbox

class AggregateDeviceInspector {

    // MARK: - Configuration
    
    enum MissingDeviceStrategy {
        case throwError        // Current behavior - throw error when device not found
        case skipMissing       // New behavior - skip disconnected devices gracefully
    }
    
    var missingDeviceStrategy: MissingDeviceStrategy = .skipMissing
    
    // Track skipped devices for logging/debugging
    private(set) var lastSkippedDevices: [(uid: String, reason: String)] = []

    // MARK: - Data Types

    struct SubDeviceInfo {
        let device: AudioDevice          // The physical device
        let uid: String                  // Device UID
        let name: String                 // Display name
        let inputChannelRange: Range<Int>?   // nil if no input
        let outputChannelRange: Range<Int>?  // nil if no output

        var isInputOnly: Bool { inputChannelRange != nil && outputChannelRange == nil }
        var isOutputOnly: Bool { outputChannelRange != nil && inputChannelRange == nil }
        var isBidirectional: Bool { inputChannelRange != nil && outputChannelRange != nil }
        
        // Helper for backward compatibility / simple access
        var startChannel: Int {
            return outputChannelRange?.lowerBound ?? inputChannelRange?.lowerBound ?? 0
        }
        
        var endChannel: Int {
            return (outputChannelRange?.upperBound ?? inputChannelRange?.upperBound ?? 1) - 1
        }
        
        var direction: Direction {
            if isInputOnly { return .input }
            if isOutputOnly { return .output }
            return .output // Default to output for bidirectional if forced to choose
        }
        
        var stereoChannelRange: Range<Int> {
            return startChannel..<(startChannel + 2)
        }
    }
    
    enum Direction {
        case input
        case output
    }

    // MARK: - Public API

    /// Check if device is an aggregate device
    func isAggregateDevice(_ device: AudioDevice) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            device.id,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uid
        )

        guard status == noErr, let _ = uid?.takeRetainedValue() as String? else {
            return false
        }

        // Check if device has sub-device list property
        propertyAddress.mSelector = kAudioAggregateDevicePropertyFullSubDeviceList
        
        return AudioObjectHasProperty(device.id, &propertyAddress)
    }

    /// Get all sub-devices in aggregate
    func getSubDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
        let uids = try getSubDeviceUIDs(aggregate: aggregate)
        
        // Build device lookup table ONCE
        let allDevices = AudioDeviceManager.getAllDevices()
        let devicesByUID = Dictionary(
            allDevices.compactMap { device -> (String, AudioDevice)? in
                guard let uid = getDeviceUID(deviceID: device.id) else { return nil }
                return (uid, device)
            },
            uniquingKeysWith: { (first, _) in first }
        )
        
        return try buildChannelMap(subDeviceUIDs: uids, deviceLookup: devicesByUID)
    }

    /// Get input sub-devices only
    func getInputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
        return try getSubDevices(aggregate: aggregate).filter { $0.inputChannelRange != nil }
    }

    /// Get output sub-devices only
    func getOutputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
        return try getSubDevices(aggregate: aggregate).filter { $0.outputChannelRange != nil }
    }

    /// Find which sub-device contains a specific channel
    func findSubDevice(
        forChannel channel: Int,
        direction: Direction,
        in aggregate: AudioDevice
    ) throws -> SubDeviceInfo? {
        let subDevices = try getSubDevices(aggregate: aggregate)
        return subDevices.first { subDevice in
            subDevice.direction == direction &&
            channel >= subDevice.startChannel &&
            channel <= subDevice.endChannel
        }
    }
    
    /// Check if aggregate device has at least one valid output device
    func hasValidOutputs(aggregate: AudioDevice) -> Bool {
        do {
            let outputs = try getOutputDevices(aggregate: aggregate)
            return !outputs.isEmpty
        } catch {
            return false
        }
    }
    
    /// Check if aggregate device has at least one valid input device
    func hasValidInputs(aggregate: AudioDevice) -> Bool {
        do {
            let inputs = try getInputDevices(aggregate: aggregate)
            return !inputs.isEmpty
        } catch {
            return false
        }
    }
    
    /// Get diagnostic info about aggregate device
    func getDeviceHealth(aggregate: AudioDevice) -> (connected: Int, missing: Int, missingUIDs: [String]) {
        lastSkippedDevices = []
        let originalStrategy = missingDeviceStrategy
        missingDeviceStrategy = .skipMissing
        
        defer { missingDeviceStrategy = originalStrategy }
        
        do {
            let devices = try getSubDevices(aggregate: aggregate)
            return (
                connected: devices.count,
                missing: lastSkippedDevices.count,
                missingUIDs: lastSkippedDevices.map { $0.uid }
            )
        } catch {
            return (connected: 0, missing: 0, missingUIDs: [])
        }
    }

    // MARK: - Private Implementation

    private func getSubDeviceUIDs(aggregate: AudioDevice) throws -> [String] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check property exists
        guard AudioObjectHasProperty(aggregate.id, &propertyAddress) else {
            throw AggregateInspectorError.notAnAggregate
        }

        var propertySize: UInt32 = 0

        // Get size
        var status = AudioObjectGetPropertyDataSize(
            aggregate.id,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else {
            throw AggregateInspectorError.propertyQueryFailed(status)
        }

        // Get data (array of CFString UIDs)
        var uidArray: Unmanaged<CFArray>?
        status = AudioObjectGetPropertyData(
            aggregate.id,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uidArray
        )

        guard status == noErr, let array = uidArray?.takeRetainedValue() as? [String] else {
            throw AggregateInspectorError.propertyQueryFailed(status)
        }

        return array
    }

    private func buildChannelMap(subDeviceUIDs: [String], deviceLookup: [String: AudioDevice]) throws -> [SubDeviceInfo] {
        var subDevices: [SubDeviceInfo] = []
        var currentInputChannel = 0
        var currentOutputChannel = 0
        
        // Reset skipped devices
        lastSkippedDevices = []

        for uid in subDeviceUIDs {
            guard let device = deviceLookup[uid] else {
                // Device not found - apply strategy
                switch missingDeviceStrategy {
                case .throwError:
                    throw AggregateInspectorError.deviceNotFound(uid: uid)
                
                case .skipMissing:
                    // Log and skip
                    lastSkippedDevices.append((uid: uid, reason: "Device not connected"))
                    Logger.log("[AggregateDeviceInspector] Skipping disconnected device: \(uid)")
                    continue // Skip this device, move to next
                }
            }

            let inputChannels = getDeviceChannelCount(device: device, isInput: true)
            let outputChannels = getDeviceChannelCount(device: device, isInput: false)
            
            var inputRange: Range<Int>? = nil
            var outputRange: Range<Int>? = nil

            // Calculate input range
            if inputChannels > 0 {
                inputRange = currentInputChannel..<(currentInputChannel + inputChannels)
                currentInputChannel += inputChannels
            }

            // Calculate output range
            if outputChannels > 0 {
                outputRange = currentOutputChannel..<(currentOutputChannel + outputChannels)
                currentOutputChannel += outputChannels
            }
            
            // Create single entry for device
            if inputRange != nil || outputRange != nil {
                subDevices.append(SubDeviceInfo(
                    device: device,
                    uid: uid,
                    name: device.name,
                    inputChannelRange: inputRange,
                    outputChannelRange: outputRange
                ))
            }
        }

        return subDevices
    }
    

    
    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &uid
        )
        
        if status == noErr {
            return uid?.takeRetainedValue() as String?
        }
        return nil
    }

    private func getDeviceChannelCount(device: AudioDevice, isInput: Bool) -> Int {
        let scope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            device.id,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(
            device.id,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            bufferListPointer
        )

        guard status == noErr else { return 0 }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)

        var totalChannels = 0
        for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
            let buffer = withUnsafePointer(to: bufferList.pointee.mBuffers) { ptr in
                ptr.advanced(by: i).pointee
            }
            totalChannels += Int(buffer.mNumberChannels)
        }

        return totalChannels
    }
}

enum AggregateInspectorError: LocalizedError {
    case notAnAggregate
    case noSubDevices
    case deviceNotFound(uid: String)
    case propertyQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notAnAggregate:
            return "Selected device is not an aggregate device"
        case .noSubDevices:
            return "Aggregate device contains no sub-devices"
        case .deviceNotFound(let uid):
            return "Sub-device '\(uid)' not found on system"
        case .propertyQueryFailed(let status):
            return "CoreAudio property query failed (error \(status))"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAnAggregate:
            return "Please select an aggregate device created in Audio MIDI Setup."
        case .noSubDevices:
            return "Please add devices to this aggregate in Audio MIDI Setup."
        case .deviceNotFound:
            return "The aggregate device references a device that is not connected. Please check Audio MIDI Setup."
        default:
            return nil
        }
    }
}
