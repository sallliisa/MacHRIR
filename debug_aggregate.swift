import CoreAudio
import Foundation

func getDeviceName(deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else { return "Unknown" }
    return name as String? ?? "Unknown"
}

func getSubDevices(aggregateDeviceID: AudioDeviceID) -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &size) == noErr else { return [] }
    
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var subDevices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &subDevices) == noErr else { return [] }
    
    return subDevices
}

func getStreamConfiguration(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
    
    let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { bufferListPtr.deallocate() }
    
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPtr) == noErr else { return 0 }
    
    let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    
    var channels = 0
    for buffer in buffers {
        channels += Int(buffer.mNumberChannels)
    }
    return channels
}

func main() {
    // Find aggregate devices
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
    
    for id in deviceIDs {
        let name = getDeviceName(deviceID: id)
        if name.localizedCaseInsensitiveContains("Aggregate") { // Simple check for now
            print("Aggregate Device: \(name) (ID: \(id))")
            
            let inputChannels = getStreamConfiguration(deviceID: id, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = getStreamConfiguration(deviceID: id, scope: kAudioObjectPropertyScopeOutput)
            print("  Total Input Channels: \(inputChannels)")
            print("  Total Output Channels: \(outputChannels)")
            
            let subDevices = getSubDevices(aggregateDeviceID: id)
            print("  Sub-Devices (\(subDevices.count)):")
            
            var currentInputOffset = 0
            var currentOutputOffset = 0
            
            for subID in subDevices {
                let subName = getDeviceName(deviceID: subID)
                let subIn = getStreamConfiguration(deviceID: subID, scope: kAudioObjectPropertyScopeInput)
                let subOut = getStreamConfiguration(deviceID: subID, scope: kAudioObjectPropertyScopeOutput)
                
                print("    - \(subName) (ID: \(subID))")
                print("      Input: \(subIn) channels (Offset: \(currentInputOffset))")
                print("      Output: \(subOut) channels (Offset: \(currentOutputOffset))")
                
                currentInputOffset += subIn
                currentOutputOffset += subOut
            }
            print("--------------------------------------------------")
        }
    }
}

main()
