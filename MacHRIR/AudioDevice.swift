//
//  AudioDevice.swift
//  MacHRIR
//
//  CoreAudio device enumeration and management
//

import Foundation
import CoreAudio
import Combine

/// Represents an audio device on the system
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let sampleRate: Double
    let channelCount: UInt32
    let isAggregateDevice: Bool

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Manager for enumerating and querying audio devices with automatic change detection
class AudioDeviceManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = AudioDeviceManager()
    
    // MARK: - Published Properties
    
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var aggregateDevices: [AudioDevice] = []
    @Published var defaultInputDevice: AudioDevice?
    @Published var defaultOutputDevice: AudioDevice?
    @Published var deviceChangeNotification: String?
    
    // MARK: - Private Properties
    
    private var deviceListenerAdded = false
    private var defaultInputListenerAdded = false
    private var defaultOutputListenerAdded = false
    
    // MARK: - Initialization
    
    private init() {
        // Initial device load
        refreshDevices()
        
        // Setup property listeners
        setupPropertyListeners()
    }
    
    deinit {
        removePropertyListeners()
    }
    
    // MARK: - Public Methods
    
    /// Refresh all device lists and defaults
    func refreshDevices() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let allDevices = Self.getAllDevices()
            self.inputDevices = allDevices.filter { $0.hasInput }
            self.outputDevices = allDevices.filter { $0.hasOutput }
            self.aggregateDevices = allDevices.filter { $0.isAggregateDevice }
            self.defaultInputDevice = Self.getDefaultInputDevice()
            self.defaultOutputDevice = Self.getDefaultOutputDevice()
        }
    }
    
    // MARK: - Property Listeners
    
    private func setupPropertyListeners() {
        // Device list changes listener
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let devicesStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            deviceListChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if devicesStatus == noErr {
            deviceListenerAdded = true
        }
        
        // Default input device listener
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let inputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            deviceListChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if inputStatus == noErr {
            defaultInputListenerAdded = true
        }
        
        // Default output device listener
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let outputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            deviceListChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if outputStatus == noErr {
            defaultOutputListenerAdded = true
        }
    }
    
    private func removePropertyListeners() {
        if deviceListenerAdded {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                deviceListChangeCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        
        if defaultInputListenerAdded {
            var defaultInputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                deviceListChangeCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        
        if defaultOutputListenerAdded {
            var defaultOutputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                deviceListChangeCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }


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
            channelCount: channelCount,
            isAggregateDevice: isAggregateDevice(deviceID: deviceID)
        )
    }

    private static func isAggregateDevice(deviceID: AudioDeviceID) -> Bool {
        // Method 1: Check Transport Type (Preferred)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        
        if AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        ) == noErr {
            // kAudioDeviceTransportTypeAggregate is 'grup' (0x67727570)
            if transportType == kAudioDeviceTransportTypeAggregate {
                return true
            }
        }

        // Method 2: Check UID (Fallback)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceUID: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &deviceUID) { ptr in
            ptr.withMemoryRebound(to: CFString?.self, capacity: 1) { reboundPtr in
                AudioObjectGetPropertyData(
                    deviceID,
                    &propertyAddress,
                    0,
                    nil,
                    &size,
                    reboundPtr
                )
            }
        }
        
        guard status == noErr, let uid = deviceUID as String? else {
            return false
        }

        // Aggregate devices usually have UIDs starting with "com.apple.audio.aggregate"
        // or contain "aggregate" in their UID if created by user.
        // Make check case-insensitive.
        return uid.localizedCaseInsensitiveContains("aggregate")
    }
    
    /// Calculates the output channel offset for the primary output device in an aggregate device.
    /// Heuristic: Skips the first sub-device (assumed to be the loopback/input) and targets the second one.
    static func getAggregateOutputOffset(deviceID: AudioDeviceID) -> Int {
        // Get sub-devices
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var subDevices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &subDevices) == noErr else { return 0 }
        
        // If only 1 device, use offset 0
        if subDevices.count < 2 { return 0 }
        
        // Calculate offset of the second device (index 1)
        // We need to sum the output channels of all previous devices (index 0)
        let firstDeviceID = subDevices[0]
        let firstDeviceOutputChannels = getChannelCount(deviceID: firstDeviceID, scope: kAudioObjectPropertyScopeOutput)
        
        return Int(firstDeviceOutputChannels)
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

        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

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

        guard let cfString = name?.takeUnretainedValue() else {
            return nil
        }

        return cfString as String
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

// MARK: - Core Audio Callbacks

/// Callback function for Core Audio property changes
private func deviceListChangeCallback(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else {
        return noErr
    }
    
    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    manager.refreshDevices()
    
    return noErr
}
