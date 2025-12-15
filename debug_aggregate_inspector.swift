import Foundation
import CoreAudio
import AudioToolbox

// Mock AudioDevice for the script since we don't have the full project context
struct AudioDevice {
    let id: AudioDeviceID
    let name: String
}

func getDeviceName(deviceID: AudioDeviceID) -> String {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var name: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    
    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &size,
        &name
    )
    
    if status == noErr, let name = name as String? {
        return name
    }
    return "Unknown Device"
}

func isAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectHasProperty(deviceID, &propertyAddress)
}

func debugAggregateDevice(_ deviceID: AudioDeviceID) {
    print("--- Debugging Device ID: \(deviceID) ---")
    print("Name: \(getDeviceName(deviceID: deviceID))")
    
    if !isAggregateDevice(deviceID) {
        print("Not an aggregate device.")
        return
    }
    
    print("Is Aggregate Device: YES")
    
    // Get SubDevice List
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
    
    if status != noErr {
        print("Error getting subdevice list size: \(status)")
        return
    }
    
    var subDeviceUIDs: CFArray?
    status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &subDeviceUIDs)
    
    if status != noErr {
        print("Error getting subdevice list data: \(status)")
        return
    }
    
    guard let uids = subDeviceUIDs as? [String] else {
        print("Could not cast subdevice list to [String]")
        return
    }
    
    print("Found \(uids.count) sub-device UIDs:")
    
    for (index, uid) in uids.enumerated() {
        print("  [\(index)] UID: \(uid)")
        
        // Try to resolve UID to DeviceID
        var subDeviceID = kAudioDeviceUnknown
        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uidString = uid as CFString
        var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translationAddress,
            UInt32(MemoryLayout<CFString>.size),
            &uidString,
            &idSize,
            &subDeviceID
        )
        
        if status == noErr && subDeviceID != kAudioDeviceUnknown {
            print("      -> Resolved to DeviceID: \(subDeviceID)")
            print("      -> Name: \(getDeviceName(deviceID: subDeviceID))")
            
            // Check channels
            let inputChannels = getChannelCount(deviceID: subDeviceID, isInput: true)
            let outputChannels = getChannelCount(deviceID: subDeviceID, isInput: false)
            print("      -> Input Channels: \(inputChannels)")
            print("      -> Output Channels: \(outputChannels)")
        } else {
            print("      -> FAILED to resolve to DeviceID (Status: \(status), ID: \(subDeviceID))")
        }
    }
}

func getChannelCount(deviceID: AudioDeviceID, isInput: Bool) -> Int {
    let scope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) != noErr { return 0 }
    
    let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { bufferListPointer.deallocate() }
    
    if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) != noErr { return 0 }
    
    let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    var count = 0
    let numBuffers = Int(bufferList.pointee.mNumberBuffers)
    
    // Need to iterate manually since AudioBufferList is a variable length struct
    var currentPtr = UnsafeMutableRawPointer(bufferListPointer).advanced(by: MemoryLayout<UInt32>.size) // Skip mNumberBuffers
    
    for _ in 0..<numBuffers {
        let buffer = currentPtr.assumingMemoryBound(to: AudioBuffer.self).pointee
        count += Int(buffer.mNumberChannels)
        currentPtr = currentPtr.advanced(by: MemoryLayout<AudioBuffer>.size)
    }
    
    return count
}

// Main execution
print("Enumerating all devices...")

var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

for id in deviceIDs {
    if isAggregateDevice(id) {
        debugAggregateDevice(id)
    }
}
