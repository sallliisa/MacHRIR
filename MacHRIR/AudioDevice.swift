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
