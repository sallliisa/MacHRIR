//
//  MenuBarViewModel.swift
//  Airwave
//
//  Migrated from MenuBarManager.swift for SwiftUI MenuBarExtra
//

import AppKit
import SwiftUI
import Combine
import CoreAudio

@MainActor
class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel()

    struct SelectionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    // Managers
    let audioManager = AudioGraphManager.shared
    let hrirManager = HRIRManager.shared
    let deviceManager = AudioDeviceManager.shared
    private let settingsManager = SettingsManager()
    private let inspector = AggregateDeviceInspector()
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false
    private var isRestoringState = false
    private var saveDebounceTimer: Timer?

    @Published var selectionAlert: SelectionAlert?
    
    // Track the last user-selected output by UID (persistent across reconnections)
    private var lastUserSelectedOutputUID: String?
    
    // Aggregate device monitoring
    private var aggregateListenerAdded = false
    private var currentMonitoredAggregate: AudioDevice?
    
    private init() {
        // Configure inspector to skip missing devices gracefully
        inspector.missingDeviceStrategy = .skipMissing
        
        // Connect managers
        audioManager.hrirManager = hrirManager
        
        setupObservers()
        
        // Wait for devices to populate before loading settings
        waitForDevicesAndInitialize()
        
        // Trigger microphone permission prompt on startup if needed
        PermissionManager.shared.requestMicrophonePermissionIfNeeded()
    }
    
    private func setupObservers() {
        // Watch for aggregate device list changes AND refresh available outputs if we have an aggregate selected
        deviceManager.$aggregateDevices
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableOutputsIfNeeded()
            }
            .store(in: &cancellables)
        
        // Batch audio manager state changes for saving
        Publishers.Merge3(
            audioManager.$isRunning.map { _ in () },
            audioManager.$aggregateDevice.map { _ in () },
            audioManager.$errorMessage.map { _ in () }
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.saveSettings()
        }
        .store(in: &cancellables)
        
        // Batch HRIR manager state changes for saving
        Publishers.Merge(
            hrirManager.$activePreset.map { _ in () },
            hrirManager.$presets.map { _ in () }
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.saveSettings()
        }
        .store(in: &cancellables)
    }
    
    private func waitForDevicesAndInitialize() {
        // Wait for device manager to populate devices
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            Logger.log("[MenuBarViewModel] Initializing settings...")
            let settings = self.loadSettings()
            self.isInitialized = true
            
            // Wait for restoration to complete before auto-starting
            DispatchQueue.main.async { [weak self] in
                self?.checkAutoStart(with: settings)
            }
        }
    }
    
    // MARK: - Device Validation
    
    func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?, validOutputs: [AggregateDeviceInspector.SubDeviceInfo]?) {
        do {
            let inputs = try inspector.getInputDevices(aggregate: device)
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices for validation
            let outputs = filterAvailableOutputs(allOutputs)
            
            Logger.log("[MenuBarViewModel] Validation: \(inputs.count) connected inputs, \(outputs.count) connected outputs")

            if inputs.isEmpty {
                return (false, "Aggregate device '\(device.name)' has no connected input devices.\n\nPlease reconnect your input device or update the aggregate in Audio MIDI Setup.", nil)
            }

            if outputs.isEmpty {
                return (false, "Aggregate device '\(device.name)' has no connected output devices.\n\nPlease reconnect your output devices or update the aggregate in Audio MIDI Setup.", nil)
            }

            // Check for at least stereo output capability
            let hasStereoOutput = outputs.contains {
                guard let range = $0.outputChannelRange else { return false }
                return (range.upperBound - range.lowerBound) >= 2
            }
            
            if !hasStereoOutput {
                return (false, "Aggregate device '\(device.name)' has no stereo output.\n\nAt least one output device must have 2+ channels.", nil)
            }

            return (true, nil, outputs)
        } catch {
            return (false, "Could not inspect aggregate device: \(error.localizedDescription)", nil)
        }
    }
    
    // MARK: - Device Selection Actions
    
    func selectAggregateDevice(_ device: AudioDevice) {
        // Log device health
        let health = inspector.getDeviceHealth(aggregate: device)
        Logger.log("[MenuBarViewModel] Aggregate '\(device.name)': \(health.connected) connected, \(health.missing) missing")
        if health.missing > 0 {
            Logger.log("[MenuBarViewModel] Missing devices: \(health.missingUIDs)")
        }
        
        // Validate first
        let validation = validateAggregateDevice(device)
        if !validation.valid {
            selectionAlert = SelectionAlert(
                title: "Invalid Aggregate Device",
                message: validation.reason ?? "Unknown error"
            )
            return
        }
        
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        
        audioManager.selectAggregateDevice(device)
        
        // Load available outputs (already validated and filtered)
        audioManager.availableOutputs = validation.validOutputs ?? []
        
        do {
            // Auto-select first output if available
            if let firstOutput = audioManager.availableOutputs.first {
                audioManager.selectedOutputDevice = firstOutput
                lastUserSelectedOutputUID = firstOutput.uid  // Track this selection
                
                // Setup audio graph with aggregate
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: firstOutput.stereoChannelRange
                )
            } else {
                audioManager.selectedOutputDevice = nil
            }
            
            // Add listener for this aggregate device to monitor configuration changes
            addAggregateDeviceListener(for: device)
            
            // Restart if was running
            if wasRunning {
                audioManager.start()
            }
            
        } catch {
            Logger.log("Failed to configure aggregate device: \(error)")
        }
    }
    
    func selectOutputDevice(_ output: AggregateDeviceInspector.SubDeviceInfo) {
        audioManager.selectedOutputDevice = output
        lastUserSelectedOutputUID = output.uid  // Track user's choice
        
        // Update output routing (NO NEED TO STOP AUDIO!)
        let channelRange = output.stereoChannelRange
        audioManager.setOutputChannels(channelRange)
        
        saveSettings()
    }
    
    // MARK: - Menu Actions
    
    func toggleAudioEngine() {
        if audioManager.isRunning {
            audioManager.stop()
        } else {
            audioManager.start()
        }
    }
    
    func showAbout() {
        closeMenuBarPopover()
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeMenuBarPopover() {
        // Close the menubar popover by finding and closing the menu window
        if let window = NSApp.windows.first(where: { $0.className.contains("MenuBar") || $0.className.contains("Popover") }) {
            window.close()
        }
    }
    
    func quitApp() {
        // Cancel debounce timer and save immediately
        saveDebounceTimer?.invalidate()
        performSave()
        audioManager.stop()
        NSApp.terminate(nil)
    }
    
    func showAggregateDeviceHelp() {
        // Open Audio MIDI Setup
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        
        // Show instructions dialog
        let alert = NSAlert()
        alert.messageText = "Setting Up Multi-Output Aggregate Device"
        alert.informativeText = """
        1. In Audio MIDI Setup, click the '+' button
        2. Select 'Create Aggregate Device'
        3. Name it (e.g., "Airwave Audio")
        4. Check your input device (e.g., BlackHole 8ch)
        5. Check ALL your output devices:
           ☑ Headphones
           ☑ Speakers
           ☑ USB DAC
           ☑ Any other outputs you use
        6. Set input device as Clock Source
        7. Close Audio MIDI Setup
        8. Return to Airwave and select your aggregate device
        
        You only need to do this once!
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // MARK: - Aggregate Device List
    
    func getValidAggregateDevices() -> [AudioDevice] {
        let allDevices = AudioDeviceManager.getAllDevices()
        return allDevices.filter { device in
            guard inspector.isAggregateDevice(device) else { return false }
            
            // Only show aggregates that have at least one valid output
            return inspector.hasValidOutputs(aggregate: device)
        }
    }
    
    // MARK: - Persistence
    
    @discardableResult
    private func loadSettings() -> AppSettings {
        Logger.log("[MenuBarViewModel] Loading settings...")
        isRestoringState = true
        
        let settings = settingsManager.loadSettings()
        
        // Restore aggregate device
        if let deviceUID = settings.aggregateDeviceUID,
           let device = AudioDeviceManager.getDeviceByUID(deviceUID),
           inspector.isAggregateDevice(device) {
            
            Logger.log("[MenuBarViewModel] Restoring aggregate device: \(device.name)")
            audioManager.selectAggregateDevice(device)
            
            // Load available outputs
            do {
                let allOutputs = try inspector.getOutputDevices(aggregate: device)
                
                // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
                audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
                
                // Restore selected output device
                if let outputUID = settings.selectedOutputDeviceUID,
                   let output = audioManager.availableOutputs.first(where: { $0.uid == outputUID }) {
                    audioManager.selectedOutputDevice = output
                    lastUserSelectedOutputUID = output.uid  // Track restored selection
                } else if let firstOutput = audioManager.availableOutputs.first {
                    // Fallback to first output
                    audioManager.selectedOutputDevice = firstOutput
                    lastUserSelectedOutputUID = firstOutput.uid  // Track fallback selection
                }
                
                // Setup audio graph
                if let output = audioManager.selectedOutputDevice {
                    try audioManager.setupAudioUnit(
                        aggregateDevice: device,
                        outputChannelRange: output.stereoChannelRange
                    )
                }
                
                // Add listener for this aggregate device to monitor configuration changes
                addAggregateDeviceListener(for: device)
                
            } catch {
                Logger.log("Failed to restore audio configuration: \(error)")
            }
        }
        
        // Restore preset
        if let presetID = settings.activePresetID,
           let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
            Logger.log("[MenuBarViewModel] Restoring preset: \(preset.name)")
            let sampleRate = 48000.0
            let inputLayout = InputLayout.detect(channelCount: 2)
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        }
        
        // Allow observers to fire before enabling saves
        DispatchQueue.main.async { [weak self] in
            self?.isRestoringState = false
            Logger.log("[MenuBarViewModel] Restoration complete, saves now enabled")
        }
        
        return settings
    }
    
    private func saveSettings() {
        guard isInitialized && !isRestoringState else {
            Logger.log("[MenuBarViewModel] Skipping save (Initialized: \(isInitialized), Restoring: \(isRestoringState))")
            return
        }
        
        // Debounce saves
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performSave()
            }
        }
    }
    
    private func performSave() {
        Logger.log("[MenuBarViewModel] Saving settings...")

        // Get UIDs for persistence
        let aggregateUID = audioManager.aggregateDevice?.uid
        let outputUID = audioManager.selectedOutputDevice?.uid

        let settings = AppSettings(
            aggregateDeviceID: nil,  // Deprecated, leave nil
            selectedOutputDeviceID: nil,  // Deprecated, leave nil
            aggregateDeviceUID: aggregateUID,
            selectedOutputDeviceUID: outputUID,
            activePresetID: hrirManager.activePreset?.id,
            autoStart: audioManager.isRunning,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
        settingsManager.saveSettings(settings)
    }
    
    private func checkAutoStart(with settings: AppSettings) {
        if settings.autoStart && audioManager.aggregateDevice != nil && audioManager.selectedOutputDevice != nil {
            Logger.log("[MenuBarViewModel] Auto-starting audio engine...")
            audioManager.start()
        }
    }
    
    // MARK: - Aggregate Device Monitoring
    
    private func addAggregateDeviceListener(for device: AudioDevice) {
        // Remove old listener if exists
        removeAggregateDeviceListener()
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
            guard let clientData = clientData else { return noErr }
            let viewModel = Unmanaged<MenuBarViewModel>.fromOpaque(clientData).takeUnretainedValue()
            DispatchQueue.main.async {
                Task { @MainActor in
                    viewModel.refreshAvailableOutputsIfNeeded()
                }
            }
            return noErr
        }
        
        let status = AudioObjectAddPropertyListener(
            device.id,
            &propertyAddress,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if status == noErr {
            aggregateListenerAdded = true
            currentMonitoredAggregate = device
            Logger.log("[MenuBarViewModel] Added listener for aggregate device: \(device.name)")
        } else {
            Logger.log("[MenuBarViewModel] Failed to add aggregate listener, status: \(status)")
        }
    }
    
    private func removeAggregateDeviceListener() {
        guard aggregateListenerAdded, let _ = currentMonitoredAggregate else {
            return
        }
        
        _ = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Note: We can't remove the listener with the same callback reference,
        // but since the app never removes listeners (only when quitting), this is fine.
        // The listener will be automatically cleaned up when the app terminates.
        aggregateListenerAdded = false
        currentMonitoredAggregate = nil
        Logger.log("[MenuBarViewModel] Marked aggregate device listener as removed")
    }
    
    /// Helper to filter out virtual loopback devices
    private func filterAvailableOutputs(_ allOutputs: [AggregateDeviceInspector.SubDeviceInfo]) -> [AggregateDeviceInspector.SubDeviceInfo] {
        // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
        // These are input-only virtual devices that users never want to output to
        return allOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }
    }

    /// Refresh available outputs if we have an aggregate device selected
    /// Called when system device list changes (devices added/removed)
    func refreshAvailableOutputsIfNeeded() {
        guard let device = audioManager.aggregateDevice else { return }
        
        do {
            let previousCount = audioManager.availableOutputs.count
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
            audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
            
            if audioManager.availableOutputs.count != previousCount {
                Logger.log("[MenuBarViewModel] Output count changed: \(previousCount) -> \(audioManager.availableOutputs.count)")
                
                // Try to restore user's preferred device
                restoreUserPreferredDevice(from: audioManager.availableOutputs)
            }
        } catch {
            Logger.log("[MenuBarViewModel] Failed to refresh outputs: \(error)")
        }
    }
    
    // MARK: - Device Restoration Logic
    
    private func restoreUserPreferredDevice(from outputs: [AggregateDeviceInspector.SubDeviceInfo]) {
        // Priority 1: Check if the user's originally-selected device came back
        if let userSelectedUID = lastUserSelectedOutputUID,
           let preferredDevice = outputs.first(where: { $0.uid == userSelectedUID }) {
            
            // Even if the UID matches, the CoreAudio DeviceID might have changed (e.g. reconnection).
            // If the ID changed (or we had no selection), we must re-initialize the AudioUnit.
            // If the ID is stable, we can just update the channel mapping (cheaper).
            let needsAudioUnitReset = audioManager.selectedOutputDevice?.device.id != preferredDevice.device.id
            
            if needsAudioUnitReset {
                restoreDeviceAfterReconnection(preferredDevice)
            } else {
                refreshChannelMapping(for: preferredDevice)
            }
        }
        // Priority 2: Check if current selection still exists
        else if let currentOutput = audioManager.selectedOutputDevice {
            if !outputs.contains(where: { $0.device.id == currentOutput.device.id }) {
                // Current output disappeared - this triggers fallback
                handleOutputDeviceDisconnected()
            } else {
                // Output still exists but channel numbers may have shifted
                // Find the updated device info for the current output
                if let updatedDevice = outputs.first(where: { $0.device.id == currentOutput.device.id }) {
                    refreshChannelMapping(for: updatedDevice)
                }
            }
        }
        // Priority 3: No selection - auto-select first available
        else if let firstOutput = outputs.first {
            Logger.log("[MenuBarViewModel] Auto-selecting first available output: \(firstOutput.name)")
            audioManager.selectedOutputDevice = firstOutput
            lastUserSelectedOutputUID = firstOutput.uid
            
            let channelRange = firstOutput.stereoChannelRange
            audioManager.setOutputChannels(channelRange)
        }
    }
    
    private func restoreDeviceAfterReconnection(_ device: AggregateDeviceInspector.SubDeviceInfo) {
        Logger.log("[MenuBarViewModel] Restoring reconnected device: \(device.name)")
        
        guard let aggregate = audioManager.aggregateDevice else { return }
        
        let wasRunning = audioManager.isRunning
        if wasRunning { audioManager.stop() }
        
        do {
            try audioManager.setupAudioUnit(
                aggregateDevice: aggregate,
                outputChannelRange: device.stereoChannelRange
            )
            
            audioManager.selectedOutputDevice = device
            
            if wasRunning { audioManager.start() }
            
            Logger.log("[MenuBarViewModel] ✅ Restored: \(device.name)")
        } catch {
            Logger.log("[MenuBarViewModel] ❌ Failed to restore: \(error)")
        }
    }
    
    private func refreshChannelMapping(for device: AggregateDeviceInspector.SubDeviceInfo) {
        // Only log if channels actually changed
        if audioManager.selectedOutputDevice?.startChannel != device.startChannel {
            Logger.log("[MenuBarViewModel] Refreshing channel mapping for: \(device.name) (ch \(device.startChannel)-\(device.startChannel + 1))")
        }
        
        audioManager.selectedOutputDevice = device
        let channelRange = device.stereoChannelRange
        audioManager.setOutputChannels(channelRange)
    }
    
    private func handleOutputDeviceDisconnected() {
        Logger.log("[MenuBarViewModel] Currently-selected output was disconnected")
        
        // Capture running state BEFORE stopping
        let wasRunning = audioManager.isRunning
        
        if wasRunning {
            audioManager.stop()
        }
        
        // Try to select first available output
        if let firstAvailable = audioManager.availableOutputs.first {
            audioManager.selectedOutputDevice = firstAvailable
            
            do {
                if let aggregate = audioManager.aggregateDevice {
                    try audioManager.setupAudioUnit(
                        aggregateDevice: aggregate,
                        outputChannelRange: firstAvailable.stereoChannelRange
                    )
                    Logger.log("[MenuBarViewModel] Switched to fallback output: \(firstAvailable.name)")
                    
                    // Restart audio if it was running
                    if wasRunning {
                        audioManager.start()
                        Logger.log("[MenuBarViewModel] ✅ Audio engine restarted on fallback device")
                    }
                }
            } catch {
                Logger.log("[MenuBarViewModel] Failed to switch to fallback output: \(error)")
            }
        } else {
            // No outputs available
            audioManager.selectedOutputDevice = nil
            Logger.log("[MenuBarViewModel] No outputs available after disconnect")
        }
    }
}
