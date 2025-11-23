import Foundation
import CoreAudio
import AudioToolbox

class AggregateDeviceInspector {

    // MARK: - Data Types

    struct SubDeviceInfo {
        let device: AudioDevice          // The physical device
        let uid: String                  // Device UID
        let name: String                 // Display name
        let startChannel: Int            // First channel in aggregate
        let channelCount: Int            // Number of channels
        let direction: Direction         // Input or output

        enum Direction {
            case input
            case output
        }

        var endChannel: Int {
            return startChannel + channelCount - 1
        }
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
        return try buildChannelMap(subDeviceUIDs: uids)
    }

    /// Get input sub-devices only
    func getInputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
        return try getSubDevices(aggregate: aggregate).filter { $0.direction == .input }
    }

    /// Get output sub-devices only
    func getOutputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
        return try getSubDevices(aggregate: aggregate).filter { $0.direction == .output }
    }

    /// Find which sub-device contains a specific channel
    func findSubDevice(
        forChannel channel: Int,
        direction: SubDeviceInfo.Direction,
        in aggregate: AudioDevice
    ) throws -> SubDeviceInfo? {
        let subDevices = try getSubDevices(aggregate: aggregate)
        return subDevices.first { subDevice in
            subDevice.direction == direction &&
            channel >= subDevice.startChannel &&
            channel <= subDevice.endChannel
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

    private func buildChannelMap(subDeviceUIDs: [String]) throws -> [SubDeviceInfo] {
        var subDevices: [SubDeviceInfo] = []
        var currentInputChannel = 0
        var currentOutputChannel = 0

        for uid in subDeviceUIDs {
            // We need to find the device by UID. 
            // Assuming AudioDevice has a static method or we can iterate all devices.
            // Since AudioDevice is a struct/class in this project, I'll use a helper or assume a way to find it.
            // The plan says `findDeviceByUID(uid)`. I will implement a helper here or use what's available.
            // Checking AudioDevice.swift might be useful, but for now I'll implement a lookup using CoreAudio if needed,
            // or rely on the existing AudioDevice wrapper if it has a way.
            // The plan implies `findDeviceByUID` exists or should be implemented.
            // I'll implement a local helper `findDeviceByUID` using CoreAudio directly to be safe, 
            // or better yet, use the AudioDevice wrapper if I can instantiate it from UID.
            
            guard let device = findDeviceByUID(uid) else {
                // If we can't find the device, we might skip it or throw. 
                // However, sub-devices in an aggregate might be hidden or special.
                // Let's try to find it.
                print("Warning: Could not find device with UID \(uid)")
                continue
            }

            let inputChannels = getDeviceChannelCount(device: device, isInput: true)
            let outputChannels = getDeviceChannelCount(device: device, isInput: false)

            // Add input mapping if device has inputs
            if inputChannels > 0 {
                subDevices.append(SubDeviceInfo(
                    device: device,
                    uid: uid,
                    name: device.name,
                    startChannel: currentInputChannel,
                    channelCount: inputChannels,
                    direction: .input
                ))
                currentInputChannel += inputChannels
            }

            // Add output mapping if device has outputs
            if outputChannels > 0 {
                subDevices.append(SubDeviceInfo(
                    device: device,
                    uid: uid,
                    name: device.name,
                    startChannel: currentOutputChannel,
                    channelCount: outputChannels,
                    direction: .output
                ))
                currentOutputChannel += outputChannels
            }
        }

        return subDevices
    }
    
    private func findDeviceByUID(_ uid: String) -> AudioDevice? {
        // Iterate all devices to find the one with matching UID.
        // This avoids kAudioHardwareBadPropertySizeError (!siz) when using kAudioHardwarePropertyDeviceForUID in Swift.
        let allDevices = AudioDeviceManager.getAllDevices()
        
        for device in allDevices {
            if let deviceUID = getDeviceUID(deviceID: device.id), deviceUID == uid {
                return device
            }
        }
        
        return nil
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

enum AggregateInspectorError: Error {
    case notAnAggregate
    case noSubDevices
    case deviceNotFound(uid: String)
    case propertyQueryFailed(OSStatus)
}
