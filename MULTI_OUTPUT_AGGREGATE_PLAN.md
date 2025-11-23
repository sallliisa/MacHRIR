# Multi-Output Aggregate Device Implementation Plan

## Executive Summary

This document outlines the implementation of a **multi-output routing system** for MacHRIR that leverages a single user-configured aggregate device containing multiple output devices. Instead of dynamically creating aggregate devices, users create ONE aggregate device with ALL their outputs, and MacHRIR routes audio to the selected output's channels.

**Primary Goal**: Enable users to switch between multiple output devices (headphones, speakers, DACs, etc.) without stopping audio or reconfiguring devices.

**Key Benefit**: Dramatically simpler than auto-creation approach while providing superior UX (instant output switching, no audio interruption).

**Key Requirement**: Users must create one aggregate device in Audio MIDI Setup (one-time, 5-minute setup).

---

## Architecture Overview

### Aggregate Device Structure (User-Configured)

```
"MacHRIR Audio" Aggregate Device:
├── Input Device: BlackHole 8ch
│   └── Channels 0-7 (Input)
├── Output Device 1: Headphones
│   └── Channels 8-9 (Output)
├── Output Device 2: Speakers
│   └── Channels 10-11 (Output)
├── Output Device 3: USB DAC
│   └── Channels 12-13 (Output)
└── Output Device 4: AirPods
    └── Channels 14-15 (Output)
```

### Audio Flow

```
Aggregate Device Input Channels (0-7)
    ↓
Audio Callback Reads Input
    ↓
HRIR Convolution → Stereo Output
    ↓
Audio Callback Writes to Selected Output Channels
    ↓
User Selection: "Speakers" → Channels 10-11
    ↓
All Other Output Channels: Zeroed
```

### Component Interactions

```
MenuBarManager
    ↓
AggregateDeviceInspector (NEW)
    ├── Enumerate sub-devices
    ├── Map channels to devices
    └── Provide device list
    ↓
AudioGraphManager (Modified)
    ├── Uses aggregate device
    └── Routes to selected output channels
```

---

## Key Implementation Components

### Component 1: AggregateDeviceInspector (New)

Responsible for analyzing an aggregate device and mapping its sub-devices to channel offsets.

```swift
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
    func isAggregateDevice(_ device: AudioDevice) -> Bool

    /// Get all sub-devices in aggregate
    func getSubDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo]

    /// Get input sub-devices only
    func getInputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo]

    /// Get output sub-devices only
    func getOutputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo]

    /// Find which sub-device contains a specific channel
    func findSubDevice(
        forChannel channel: Int,
        direction: SubDeviceInfo.Direction,
        in aggregate: AudioDevice
    ) throws -> SubDeviceInfo?

    // MARK: - Private Implementation

    private func getSubDeviceUIDs(aggregate: AudioDevice) throws -> [String]
    private func buildChannelMap(subDeviceUIDs: [String]) throws -> [SubDeviceInfo]
    private func getDeviceChannelCount(device: AudioDevice, isInput: Bool) -> Int
}

enum AggregateInspectorError: Error {
    case notAnAggregate
    case noSubDevices
    case deviceNotFound(uid: String)
    case propertyQueryFailed(OSStatus)
}
```

### Component 2: AudioGraphManager (Modified)

Update to support channel-based output routing.

```swift
class AudioGraphManager {

    // MARK: - Properties

    private var audioUnit: AudioUnit?
    private var aggregateDevice: AudioDevice?

    // NEW: Track which output channels to use
    private var selectedOutputChannelRange: Range<Int>?  // e.g., 10..<12 for speakers

    // Pre-allocated buffers
    private var inputBufferList: UnsafeMutablePointer<AudioBufferList>
    private var inputChannelBuffers: [UnsafeMutablePointer<Float>]

    // MARK: - Configuration

    /// Setup with aggregate device and optional output channel specification
    func setupAudioUnit(
        aggregateDevice: AudioDevice,
        outputChannelRange: Range<Int>? = nil  // If nil, use first stereo pair
    ) throws

    /// Change output routing without stopping audio
    func setOutputChannels(_ range: Range<Int>)

    // MARK: - Render Callback

    func renderCallback(
        inRefCon: UnsafeMutableRawPointer,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderCallbackStruct>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {

        // 1. Pull input from aggregate device
        AudioUnitRender(audioUnit, ..., inputBufferList)

        // 2. Process through HRIR convolution
        // Input: inputChannelBuffers
        // Output: leftOutputBuffer, rightOutputBuffer
        hrirManager.processFrame(...)

        // 3. Zero ALL output channels first
        let outputBufferList = ioData!.pointee
        for i in 0..<Int(outputBufferList.mNumberBuffers) {
            memset(
                outputBufferList.mBuffers[i].mData,
                0,
                Int(outputBufferList.mBuffers[i].mDataByteSize)
            )
        }

        // 4. Write stereo output to selected channels only
        if let channelRange = selectedOutputChannelRange {
            let leftChannel = channelRange.lowerBound
            let rightChannel = leftChannel + 1

            if rightChannel < outputBufferList.mNumberBuffers {
                memcpy(
                    outputBufferList.mBuffers[leftChannel].mData,
                    leftOutputBuffer,
                    bufferByteSize
                )
                memcpy(
                    outputBufferList.mBuffers[rightChannel].mData,
                    rightOutputBuffer,
                    bufferByteSize
                )
            }
        }

        return noErr
    }
}
```

### Component 3: MenuBarManager (Modified)

Update UI to show aggregate device selector and output device selector.

```swift
class MenuBarManager {

    // MARK: - Properties

    private let inspector = AggregateDeviceInspector()

    private var selectedAggregate: AudioDevice?
    private var selectedOutputDevice: AggregateDeviceInspector.SubDeviceInfo?
    private var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] = []

    // MARK: - Menu Building

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Aggregate device selector
        let aggItem = NSMenuItem(
            title: "Aggregate Device",
            action: nil,
            keyEquivalent: ""
        )
        aggItem.submenu = buildAggregateDeviceMenu()
        menu.addItem(aggItem)

        // Output device selector (only if aggregate selected)
        if selectedAggregate != nil {
            let outItem = NSMenuItem(
                title: "Output Device",
                action: nil,
                keyEquivalent: ""
            )
            outItem.submenu = buildOutputDeviceMenu()
            menu.addItem(outItem)
        } else {
            // Show help message
            let helpItem = NSMenuItem(
                title: "↑ Select aggregate device first",
                action: nil,
                keyEquivalent: ""
            )
            helpItem.isEnabled = false
            menu.addItem(helpItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Status indicator
        if let output = selectedOutputDevice {
            let statusItem = NSMenuItem(
                title: "→ Playing to: \(output.name)",
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        // Rest of menu (presets, controls, etc.)
        // ...

        menu.addItem(NSMenuItem.separator())

        // Help: Setup instructions
        let setupItem = NSMenuItem(
            title: "Help: Setting Up Aggregate Device",
            action: #selector(showSetupInstructions(_:)),
            keyEquivalent: ""
        )
        setupItem.target = self
        menu.addItem(setupItem)

        return menu
    }

    private func buildAggregateDeviceMenu() -> NSMenu {
        let menu = NSMenu()

        let allDevices = deviceManager.allDevices
        let aggregates = allDevices.filter { inspector.isAggregateDevice($0) }

        if aggregates.isEmpty {
            let item = NSMenuItem(
                title: "No aggregate devices found",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)

            menu.addItem(NSMenuItem.separator())

            let helpItem = NSMenuItem(
                title: "Create Aggregate Device...",
                action: #selector(showSetupInstructions(_:)),
                keyEquivalent: ""
            )
            helpItem.target = self
            menu.addItem(helpItem)
        } else {
            for aggregate in aggregates {
                let item = NSMenuItem(
                    title: aggregate.name,
                    action: #selector(selectAggregateDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = aggregate
                item.state = (aggregate.id == selectedAggregate?.id) ? .on : .off
                menu.addItem(item)
            }
        }

        return menu
    }

    private func buildOutputDeviceMenu() -> NSMenu {
        let menu = NSMenu()

        guard let aggregate = selectedAggregate else {
            return menu
        }

        // Get output devices from aggregate
        do {
            availableOutputs = try inspector.getOutputDevices(aggregate: aggregate)

            if availableOutputs.isEmpty {
                let item = NSMenuItem(
                    title: "No output devices in aggregate",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for output in availableOutputs {
                    let channelInfo = "Ch \(output.startChannel)-\(output.endChannel)"
                    let item = NSMenuItem(
                        title: "\(output.name) (\(channelInfo))",
                        action: #selector(selectOutputDevice(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = output
                    item.state = (output.device.id == selectedOutputDevice?.device.id) ? .on : .off
                    menu.addItem(item)
                }
            }
        } catch {
            let item = NSMenuItem(
                title: "Error reading aggregate: \(error)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        return menu
    }

    // MARK: - Actions

    @objc func selectAggregateDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else {
            return
        }

        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }

        selectedAggregate = device
        SettingsManager.shared.setAggregateDevice(device.id)

        // Load available outputs
        do {
            availableOutputs = try inspector.getOutputDevices(aggregate: device)

            // Auto-select first output if available
            if let firstOutput = availableOutputs.first {
                selectedOutputDevice = firstOutput
                SettingsManager.shared.setOutputDevice(firstOutput.device.id)
            }

            // Setup audio graph with aggregate
            try audioManager.setupAudioUnit(
                aggregateDevice: device,
                outputChannelRange: selectedOutputDevice.map { $0.startChannel..<($0.startChannel + 2) }
            )

            // Restart if was running
            if wasRunning {
                audioManager.start()
            }

        } catch {
            showAlert(
                title: "Configuration Error",
                message: "Failed to configure aggregate device: \(error.localizedDescription)"
            )
        }

        rebuildMenu()
    }

    @objc func selectOutputDevice(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else {
            return
        }

        selectedOutputDevice = output
        SettingsManager.shared.setOutputDevice(output.device.id)

        // Update output routing (NO NEED TO STOP AUDIO!)
        let channelRange = output.startChannel..<(output.startChannel + 2)
        audioManager.setOutputChannels(channelRange)

        rebuildMenu()
    }

    @objc func showSetupInstructions(_ sender: NSMenuItem) {
        // Open Audio MIDI Setup
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        )

        // Show instructions dialog
        let alert = NSAlert()
        alert.messageText = "Setting Up Multi-Output Aggregate Device"
        alert.informativeText = """
        1. In Audio MIDI Setup, click the '+' button
        2. Select 'Create Aggregate Device'
        3. Name it (e.g., "MacHRIR Audio")
        4. Check your input device (e.g., BlackHole 8ch)
        5. Check ALL your output devices:
           ☑ Headphones
           ☑ Speakers
           ☑ USB DAC
           ☑ Any other outputs you use
        6. Set input device as Clock Source
        7. Close Audio MIDI Setup
        8. Return to MacHRIR and select your aggregate device

        You only need to do this once!
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

### Component 4: SettingsManager (Modified)

Update to persist aggregate device and output device selections.

```swift
class SettingsManager {

    enum SettingsKey {
        static let aggregateDeviceID = "aggregateDeviceID"        // AudioDeviceID
        static let selectedOutputDeviceID = "selectedOutputDeviceID"  // AudioDeviceID
        static let selectedPresetName = "selectedPresetName"
        static let convolutionEnabled = "convolutionEnabled"
    }

    func setAggregateDevice(_ deviceID: AudioDeviceID) {
        UserDefaults.standard.set(Int(deviceID), forKey: SettingsKey.aggregateDeviceID)
    }

    func getAggregateDevice() -> AudioDeviceID? {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.aggregateDeviceID)
        return value > 0 ? AudioDeviceID(value) : nil
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        UserDefaults.standard.set(Int(deviceID), forKey: SettingsKey.selectedOutputDeviceID)
    }

    func getOutputDevice() -> AudioDeviceID? {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.selectedOutputDeviceID)
        return value > 0 ? AudioDeviceID(value) : nil
    }
}
```

---

## Detailed Implementation

### Phase 1: AggregateDeviceInspector Implementation

#### Step 1.1: Aggregate Detection

```swift
func isAggregateDevice(_ device: AudioDevice) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var uid: CFString?
    var propertySize = UInt32(MemoryLayout<CFString?>.size)

    let status = AudioObjectGetPropertyData(
        device.id,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &uid
    )

    guard status == noErr, let uidString = uid as String? else {
        return false
    }

    // Aggregate devices have UIDs containing "aggregate" or use different property
    // More reliable: Check if device has sub-device list property
    propertyAddress.mSelector = kAudioAggregateDevicePropertyFullSubDeviceList

    let hasProperty = AudioObjectHasProperty(device.id, &propertyAddress)
    return hasProperty
}
```

#### Step 1.2: Sub-Device Enumeration

```swift
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
    var uidArray: CFArray?
    status = AudioObjectGetPropertyData(
        aggregate.id,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &uidArray
    )

    guard status == noErr, let array = uidArray as? [String] else {
        throw AggregateInspectorError.propertyQueryFailed(status)
    }

    return array
}
```

#### Step 1.3: Channel Mapping

```swift
private func buildChannelMap(subDeviceUIDs: [String]) throws -> [SubDeviceInfo] {
    var subDevices: [SubDeviceInfo] = []
    var currentInputChannel = 0
    var currentOutputChannel = 0

    for uid in subDeviceUIDs {
        guard let device = findDeviceByUID(uid) else {
            throw AggregateInspectorError.deviceNotFound(uid: uid)
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
```

#### Step 1.4: Public API Implementation

```swift
func getSubDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
    let uids = try getSubDeviceUIDs(aggregate: aggregate)
    return try buildChannelMap(subDeviceUIDs: uids)
}

func getInputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
    return try getSubDevices(aggregate: aggregate).filter { $0.direction == .input }
}

func getOutputDevices(aggregate: AudioDevice) throws -> [SubDeviceInfo] {
    return try getSubDevices(aggregate: aggregate).filter { $0.direction == .output }
}

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
```

### Phase 2: AudioGraphManager Updates

#### Step 2.1: Add Output Channel Tracking

```swift
class AudioGraphManager {
    // Existing properties...

    private var selectedOutputChannelRange: Range<Int>?
    private var totalOutputChannels: Int = 0

    func setupAudioUnit(
        aggregateDevice: AudioDevice,
        outputChannelRange: Range<Int>? = nil
    ) throws {

        self.aggregateDevice = aggregateDevice
        self.selectedOutputChannelRange = outputChannelRange

        // Create audio unit
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioGraphError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioGraphError.initializationFailed(status)
        }

        self.audioUnit = audioUnit

        // Enable I/O
        var enableIO: UInt32 = 1

        // Enable input (element 1)
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioGraphError.configurationFailed(status)
        }

        // Enable output (element 0) - already enabled by default

        // Set aggregate device
        var deviceID = aggregateDevice.id
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioGraphError.deviceSetupFailed(status)
        }

        // Get stream formats
        let inputChannels = aggregateDevice.inputChannelCount
        let outputChannels = aggregateDevice.outputChannelCount
        totalOutputChannels = outputChannels

        let sampleRate = try getSampleRate(device: aggregateDevice)

        // Configure input format (element 1, input scope)
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                          kAudioFormatFlagIsPacked |
                          kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(inputChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,  // Output of input element
            1,
            &inputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioGraphError.formatSetupFailed(status)
        }

        // Configure output format (element 0, output scope)
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                          kAudioFormatFlagIsPacked |
                          kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(outputChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,  // Input of output element
            0,
            &outputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioGraphError.formatSetupFailed(status)
        }

        // Pre-allocate buffers...
        // Set render callback...
        // Initialize audio unit...

        // (Rest of existing setup code)
    }

    func setOutputChannels(_ range: Range<Int>) {
        // Thread-safe update of output channel range
        // No need to reinitialize audio unit!
        selectedOutputChannelRange = range
    }
}
```

#### Step 2.2: Update Render Callback

```swift
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderCallbackStruct>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {

    let manager = Unmanaged<AudioGraphManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let outputBufferList = ioData else {
        return kAudio_ParamError
    }

    // 1. Pull input from aggregate device (element 1)
    var status = AudioUnitRender(
        manager.audioUnit!,
        ioActionFlags,
        inTimeStamp,
        1,  // Element 1 (input)
        inNumberFrames,
        manager.inputBufferList
    )

    guard status == noErr else {
        return status
    }

    // 2. Process HRIR convolution
    if manager.convolutionEnabled {
        manager.hrirManager.processFrame(
            inputBuffers: manager.inputChannelBuffers,
            inputChannelCount: manager.inputChannelCount,
            outputLeft: manager.leftOutputBuffer,
            outputRight: manager.rightOutputBuffer,
            frameCount: Int(inNumberFrames)
        )
    } else {
        // Pass through first two channels
        memcpy(
            manager.leftOutputBuffer,
            manager.inputChannelBuffers[0],
            Int(inNumberFrames) * MemoryLayout<Float>.size
        )
        if manager.inputChannelBuffers.count > 1 {
            memcpy(
                manager.rightOutputBuffer,
                manager.inputChannelBuffers[1],
                Int(inNumberFrames) * MemoryLayout<Float>.size
            )
        }
    }

    // 3. Zero ALL output channels
    let bufferList = outputBufferList.pointee
    let byteSize = Int(inNumberFrames) * MemoryLayout<Float>.size

    for i in 0..<Int(bufferList.mNumberBuffers) {
        let buffer = withUnsafePointer(to: bufferList.mBuffers) { ptr in
            ptr.advanced(by: i).pointee
        }
        memset(buffer.mData, 0, byteSize)
    }

    // 4. Write stereo output to SELECTED channels only
    if let channelRange = manager.selectedOutputChannelRange {
        let leftChannel = channelRange.lowerBound
        let rightChannel = leftChannel + 1

        // Bounds check
        if rightChannel < Int(bufferList.mNumberBuffers) {
            let leftBuffer = withUnsafePointer(to: bufferList.mBuffers) { ptr in
                ptr.advanced(by: leftChannel).pointee
            }
            let rightBuffer = withUnsafePointer(to: bufferList.mBuffers) { ptr in
                ptr.advanced(by: rightChannel).pointee
            }

            memcpy(leftBuffer.mData, manager.leftOutputBuffer, byteSize)
            memcpy(rightBuffer.mData, manager.rightOutputBuffer, byteSize)
        }
    }

    return noErr
}
```

### Phase 3: Settings Restoration on Launch

```swift
// In MenuBarManager or AppDelegate:

func restoreSettings() {
    // Restore aggregate device
    if let deviceID = SettingsManager.shared.getAggregateDevice(),
       let device = deviceManager.deviceWithID(deviceID),
       inspector.isAggregateDevice(device) {

        selectedAggregate = device

        // Load available outputs
        do {
            availableOutputs = try inspector.getOutputDevices(aggregate: device)

            // Restore selected output device
            if let outputID = SettingsManager.shared.getOutputDevice(),
               let output = availableOutputs.first(where: { $0.device.id == outputID }) {
                selectedOutputDevice = output
            } else if let firstOutput = availableOutputs.first {
                // Fallback to first output
                selectedOutputDevice = firstOutput
            }

            // Setup audio graph
            try audioManager.setupAudioUnit(
                aggregateDevice: device,
                outputChannelRange: selectedOutputDevice.map {
                    $0.startChannel..<($0.startChannel + 2)
                }
            )

        } catch {
            print("Failed to restore audio configuration: \(error)")
        }
    }
}
```

---

## User Documentation

### Setup Guide for Users

```markdown
# MacHRIR: Setting Up Multi-Output Aggregate Device

MacHRIR uses an **aggregate device** to enable seamless switching between
multiple output devices (headphones, speakers, DACs, etc.) without interrupting
audio playback.

## One-Time Setup (5 minutes)

### Step 1: Open Audio MIDI Setup
1. Open **Finder**
2. Go to **Applications → Utilities**
3. Launch **Audio MIDI Setup**

### Step 2: Create Aggregate Device
1. Click the **+** button in the bottom-left corner
2. Select **Create Aggregate Device**
3. A new device appears named "Aggregate Device"

### Step 3: Rename Your Device
1. Double-click "Aggregate Device"
2. Rename it to something memorable (e.g., "MacHRIR Audio")

### Step 4: Add Your Input Device
1. Find your multi-channel input device (e.g., BlackHole 8ch, Soundflower, etc.)
2. **Check the box** next to it to add it to the aggregate

### Step 5: Add ALL Your Output Devices
This is the key step! Add every output device you might want to use:
- ☑ Headphones
- ☑ Built-in Speakers
- ☑ USB DAC
- ☑ Bluetooth Speakers
- ☑ AirPods
- ☑ Any other audio outputs

**Check the box next to each one.**

### Step 6: Set Clock Master
1. In the **Clock Source** column (right side)
2. Find your input device (e.g., BlackHole 8ch)
3. Select it as the clock master using the dropdown

### Step 7: Close Audio MIDI Setup
Your aggregate device is now configured!

## Using MacHRIR

### First Time
1. Launch MacHRIR
2. Click the menu bar icon
3. Select **Aggregate Device → MacHRIR Audio** (or whatever you named it)
4. Select **Output Device** → Choose which output to use (e.g., Headphones)
5. Add your HRIR preset
6. Enable convolution
7. Click **Start**

### Switching Outputs
To switch from Headphones to Speakers:
1. Click **Output Device → Speakers**
2. That's it! Audio continues playing, now through speakers.

**No need to stop/restart audio!**

## Troubleshooting

### "No output devices in aggregate"
- Your aggregate device doesn't have any output devices configured
- Open Audio MIDI Setup and add output devices (Step 5 above)

### "No audio coming out"
- Make sure you selected the correct output device in MacHRIR menu
- Check that the device is working in System Preferences → Sound
- Try stopping and starting audio in MacHRIR

### "Audio sounds glitchy/crackly"
- One of your devices may not support the aggregate's sample rate
- In Audio MIDI Setup, check that all devices support the same rate (e.g., 48000 Hz)
- Set all devices to the same sample rate in Audio MIDI Setup

### "Device disappeared after wake from sleep"
- Some USB audio devices disconnect on sleep
- Check cable connections
- Try stopping and restarting audio in MacHRIR

## Adding More Outputs Later

You can always add more output devices:
1. Open Audio MIDI Setup
2. Select your aggregate device
3. Check the box next to the new device
4. Return to MacHRIR - it will appear in the Output Device menu
```

---

## Testing Strategy

### Unit Tests

```swift
class AggregateDeviceInspectorTests: XCTestCase {
    var inspector: AggregateDeviceInspector!

    override func setUp() {
        inspector = AggregateDeviceInspector()
    }

    func testAggregateDetection() {
        // Create test aggregate device manually
        // Verify isAggregateDevice returns true
    }

    func testSubDeviceEnumeration() throws {
        let aggregate = // Get test aggregate
        let subDevices = try inspector.getSubDevices(aggregate: aggregate)

        XCTAssertFalse(subDevices.isEmpty)

        // Verify channel mapping is contiguous
        var expectedChannel = 0
        for subDevice in subDevices.filter({ $0.direction == .output }) {
            XCTAssertEqual(subDevice.startChannel, expectedChannel)
            expectedChannel += subDevice.channelCount
        }
    }

    func testInputOutputSeparation() throws {
        let aggregate = // Get test aggregate
        let inputs = try inspector.getInputDevices(aggregate: aggregate)
        let outputs = try inspector.getOutputDevices(aggregate: aggregate)

        XCTAssertFalse(inputs.isEmpty)
        XCTAssertFalse(outputs.isEmpty)

        // Verify no overlap
        let inputIDs = Set(inputs.map { $0.device.id })
        let outputIDs = Set(outputs.map { $0.device.id })
        // Note: Same device can be in both if it has input and output
    }

    func testChannelLookup() throws {
        let aggregate = // Get test aggregate

        // Test finding device for output channel 10
        let subDevice = try inspector.findSubDevice(
            forChannel: 10,
            direction: .output,
            in: aggregate
        )

        XCTAssertNotNil(subDevice)
        XCTAssertTrue(10 >= subDevice!.startChannel)
        XCTAssertTrue(10 <= subDevice!.endChannel)
    }
}

class AudioGraphManagerMultiOutputTests: XCTestCase {
    func testOutputChannelSwitching() {
        // Setup audio graph with aggregate
        // Switch output channels while running
        // Verify audio continues without interruption
    }

    func testChannelRangeBoundsChecking() {
        // Test with invalid channel ranges
        // Verify no crashes or errors
    }
}
```

### Manual Testing Checklist

#### Setup & Configuration
- [ ] User can create aggregate device in Audio MIDI Setup
- [ ] MacHRIR detects aggregate devices correctly
- [ ] Aggregate device with 1 input + 3 outputs shows all outputs in menu
- [ ] Channel numbers displayed correctly in menu (e.g., "Headphones (Ch 8-9)")
- [ ] Settings persist across app restarts

#### Output Switching
- [ ] Select Output Device → Audio routes to correct device
- [ ] Switch outputs while audio playing → No interruption
- [ ] Switch outputs while audio paused → Works correctly
- [ ] Audio quality identical across all outputs
- [ ] No clicks/pops when switching outputs

#### Edge Cases
- [ ] Aggregate with only 1 output device → Works correctly
- [ ] Aggregate with 5+ output devices → All shown in menu
- [ ] Output device disconnected while selected → Error handling
- [ ] Output device reconnected → Available in menu again
- [ ] Switch rapidly between outputs → No crashes

#### Stability
- [ ] 24-hour continuous operation with output switching
- [ ] No memory leaks
- [ ] CPU usage stable
- [ ] No clock drift (aggregate device handles sync)

#### Multi-Channel Support
- [ ] 2.0 input → 7.1.4 HRIR → Stereo output works
- [ ] 5.1 input → 5.1 HRIR → Stereo output works
- [ ] 7.1 input → 7.1 HRIR → Stereo output works
- [ ] Different channel counts for different output devices

#### HRIR Processing
- [ ] Convolution works correctly with multi-output aggregate
- [ ] Preset switching works while using aggregate
- [ ] All existing HRIR features work unchanged

#### Error Handling
- [ ] No aggregate devices → Clear help message
- [ ] Aggregate with no outputs → Clear error message
- [ ] Aggregate device disappears while running → Graceful handling
- [ ] Invalid aggregate selection → Clear error message

---

## Implementation Timeline

### Phase 1: AggregateDeviceInspector (3-4 days)
- [ ] Implement aggregate detection
- [ ] Implement sub-device enumeration
- [ ] Implement channel mapping
- [ ] Unit tests
- [ ] Manual testing with real aggregate devices

### Phase 2: AudioGraphManager Updates (2-3 days)
- [ ] Add output channel range tracking
- [ ] Update render callback for selective channel output
- [ ] Implement hot-swap channel switching
- [ ] Test audio routing correctness

### Phase 3: MenuBarManager Integration (2-3 days)
- [ ] Add aggregate device selector menu
- [ ] Add output device selector menu
- [ ] Implement device selection actions
- [ ] Update status indicators

### Phase 4: Settings & Persistence (1 day)
- [ ] Update settings schema
- [ ] Implement settings save/restore
- [ ] Test settings persistence

### Phase 5: User Documentation (1-2 days)
- [ ] Write setup guide
- [ ] Create troubleshooting guide
- [ ] Add in-app help
- [ ] Update CLAUDE.md

### Phase 6: Testing & Polish (3-4 days)
- [ ] Complete manual testing checklist
- [ ] 24-hour stability test
- [ ] Performance profiling
- [ ] Bug fixes
- [ ] UI polish

**Total Estimated Duration: 12-17 days**

---

## Comparison: Auto-Creation vs Multi-Output

| Aspect | Auto-Creation | Multi-Output (This Plan) |
|--------|---------------|-------------------------|
| **Implementation Complexity** | Very High (500+ lines) | Low (200-300 lines) |
| **API Deprecation Risk** | HIGH | NONE |
| **User Setup** | None (automatic) | One-time (5 min) |
| **Output Switching** | Stop audio, recreate device | Instant, no interruption |
| **Reliability** | Medium (timing, race conditions) | Very High (simple routing) |
| **Maintenance** | High (cleanup, edge cases) | Low (straightforward logic) |
| **Device Persistence** | Temporary (app-managed) | Permanent (user-managed) |
| **User Control** | Limited (automatic decisions) | Full (user configures everything) |
| **Code Complexity** | High (lifecycle management) | Low (channel routing) |
| **Testing Surface** | Large (many failure modes) | Small (few failure modes) |

**Winner: Multi-Output approach is superior in almost every dimension.**

---

## Migration from Current Branch

### Current State
- Branch: `system_aggregate_device`
- Already uses single aggregate device architecture
- AudioGraphManager uses single Audio Unit

### Migration Steps

1. **Add AggregateDeviceInspector.swift** (new file)
   - Implement all methods from this plan

2. **Update AudioGraphManager.swift**
   - Add `selectedOutputChannelRange` property
   - Add `setOutputChannels()` method
   - Update render callback to zero unused channels
   - Update render callback to write to selected channels only

3. **Update MenuBarManager.swift**
   - Replace single device selector with:
     - Aggregate device selector
     - Output device selector
   - Add output switching action
   - Add setup instructions action

4. **Update SettingsManager.swift**
   - Add `aggregateDeviceID` setting
   - Add `selectedOutputDeviceID` setting
   - Remove old input/output device settings (if any)

5. **Testing**
   - Create test aggregate device
   - Test all functionality from checklist
   - 24-hour stability test

---

## Success Criteria

### Must Have
✅ Aggregate device detection works correctly
✅ Sub-device enumeration accurate for all tested aggregates
✅ Channel mapping correct for all output devices
✅ Output switching works without audio interruption
✅ No memory leaks
✅ CPU usage ≤ current implementation
✅ All HRIR processing works unchanged

### Should Have
✅ Clear setup instructions for users
✅ Helpful error messages
✅ Settings persistence
✅ Device hot-plug detection
✅ 24-hour stability test passes

### Nice to Have
⏳ Visual channel mapping diagram in UI
⏳ Auto-detect clock drift issues and warn user
⏳ Aggregate device validation (check configuration)
⏳ In-app aggregate device creation wizard (future)

---

## Advantages of This Approach

### 1. Simplicity
- No device creation/destruction
- No API deprecation concerns
- Straightforward channel routing
- Easy to understand and maintain

### 2. Reliability
- No timing issues
- No race conditions
- No orphaned devices
- Fewer failure modes

### 3. User Experience
- One-time setup
- Instant output switching
- No audio interruption
- Full user control

### 4. Performance
- Zero overhead for device management
- Same CPU usage as current single-aggregate approach
- No latency from device recreation

### 5. Maintainability
- Simple codebase (~300 lines total)
- Few edge cases
- Easy to debug
- Clear failure modes

---

## Conclusion

The multi-output aggregate approach is **dramatically simpler and more reliable** than auto-creation while providing **superior UX** for output switching. The only tradeoff is a one-time 5-minute setup, which users only need to do once.

**Key Benefits:**
1. ✅ No deprecated API usage
2. ✅ Instant output switching without audio interruption
3. ✅ 1/5th the implementation complexity
4. ✅ Fewer failure modes and edge cases
5. ✅ User has full control over configuration

**Recommendation: This is the correct approach for MacHRIR.**

The aggregate device persistence is actually a **feature**, not a bug - users configure it once and it works forever, even across app updates or reinstalls.

---

## References

1. **CoreAudio Documentation** - [kAudioAggregateDevicePropertyFullSubDeviceList](https://developer.apple.com/documentation/coreaudio)
2. **Audio MIDI Setup User Guide** - [Apple Support](https://support.apple.com/guide/audio-midi-setup/welcome/mac)
3. **CoreAudio Property Reference** - AudioHardware.h header file

---

*Document Version: 1.0*
*Last Updated: 2025-11-23*
*Approach: Multi-Output Aggregate with Channel Routing*
*Branch: system_aggregate_device*
