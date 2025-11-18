//
//  AudioDevice.swift
//  MacHRIR
//
//  CoreAudio device enumeration and management
//

import Foundation
import CoreAudio

/// Represents an audio device on the system
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let sampleRate: Double
    let channelCount: UInt32

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Manager for enumerating and querying audio devices
class AudioDeviceManager {

    /// Get all audio devices on the system
    static func getAllDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            return getDeviceInfo(deviceID: deviceID)
        }
    }

    /// Get devices that have input capability
    static func getInputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.hasInput }
    }

    /// Get devices that have output capability
    static func getOutputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.hasOutput }
    }

    /// Get the system default input device
    static func getDefaultInputDevice() -> AudioDevice? {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }

        return getDeviceInfo(deviceID: deviceID)
    }

    /// Get the system default output device
    static func getDefaultOutputDevice() -> AudioDevice? {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }

        return getDeviceInfo(deviceID: deviceID)
    }

    /// Get detailed information about a specific device
    static func getDeviceInfo(deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = getDeviceName(deviceID: deviceID) else {
            return nil
        }

        let hasInput = getChannelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) > 0
        let hasOutput = getChannelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput) > 0

        let channelCount = hasInput ?
            getChannelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) :
            getChannelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)

        let sampleRate = getSampleRate(deviceID: deviceID)

        return AudioDevice(
            id: deviceID,
            name: name,
            hasInput: hasInput,
            hasOutput: hasOutput,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    // MARK: - Private Helper Methods

    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &name
        ) == noErr else {
            return nil
        }

        return name as String
    }

    private static func getChannelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferListPointer
        ) == noErr else {
            return 0
        }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        var channelCount: UInt32 = 0
        for buffer in buffers {
            channelCount += buffer.mNumberChannels
        }

        return channelCount
    }

    private static func getSampleRate(deviceID: AudioDeviceID) -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Double = 48000.0
        var dataSize = UInt32(MemoryLayout<Double>.size)

        AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &sampleRate
        )

        return sampleRate
    }
}
