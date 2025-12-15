import CoreAudio
import Foundation

func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
    
    var stringRef: CFString?
    var propSize = UInt32(MemoryLayout<CFString?>.size)
    
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &stringRef) == noErr else { return nil }
    
    return stringRef as String?
}

func getDeviceTransportType(deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var transportType: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else { return nil }
    
    return transportType
}

func main() {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        print("Error getting device list size")
        return
    }
    
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
        print("Error getting device list")
        return
    }
    
    print("Found \(count) devices:")
    print("--------------------------------------------------")
    
    for id in deviceIDs {
        let name = getDeviceStringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown"
        let uid = getDeviceStringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown"
        let manufacturer = getDeviceStringProperty(deviceID: id, selector: kAudioObjectPropertyManufacturer) ?? "Unknown"
        let transportType = getDeviceTransportType(deviceID: id)
        
        print("ID: \(id)")
        print("Name: \(name)")
        print("UID: \(uid)")
        print("Manufacturer: \(manufacturer)")
        if let type = transportType {
            let typeString = String(format: "%c%c%c%c", 
                (type >> 24) & 0xff, 
                (type >> 16) & 0xff, 
                (type >> 8) & 0xff, 
                type & 0xff)
            print("Transport Type: \(type) ('\(typeString)')") // kAudioDeviceTransportTypeAggregate is 'grup' (0x67727570)
        }
        print("--------------------------------------------------")
    }
}

main()
