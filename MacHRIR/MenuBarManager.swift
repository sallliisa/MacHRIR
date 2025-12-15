//
//  MenuBarManager.swift
//  MacHRIR
//
//  Created by gamer on 22/11/25.
//
//  Updated for Aggregate Device Architecture with Multi-Output Support
//

import AppKit
import SwiftUI
import Combine
import CoreAudio

class MenuBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    
    // Managers
    private let audioManager = AudioGraphManager()
    private let hrirManager = HRIRManager()
    private let deviceManager = AudioDeviceManager.shared
    private let settingsManager = SettingsManager()
    private let inspector = AggregateDeviceInspector()
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false
    private var isRestoringState = false
    private var saveDebounceTimer: Timer?
    
    // State
    private var selectedOutputDevice: AggregateDeviceInspector.SubDeviceInfo?
    private var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] = []
    
    // Track the last user-selected output by UID (persistent across reconnections)
    private var lastUserSelectedOutputUID: String?
    
    // Aggregate device monitoring
    private var aggregateListenerAdded = false
    private var currentMonitoredAggregate: AudioDevice?
    
    override init() {
        super.init()
        
        // Configure inspector to skip missing devices gracefully
        inspector.missingDeviceStrategy = .skipMissing
        
        // Connect managers
        audioManager.hrirManager = hrirManager
        
        setupStatusItem()
        setupObservers()
        
        // Wait for devices to populate before loading settings
        waitForDevicesAndInitialize()
        
        // Check permissions on startup
        PermissionManager.shared.checkAndRequestMicrophonePermission { granted in
            if !granted {
                Logger.log("[MenuBarManager] ⚠️ Microphone permission denied")
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "MacHRIR")
        }
        
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        updateMenu()
    }
    
    private func setupObservers() {
        // Watch for aggregate device list changes AND refresh available outputs if we have an aggregate selected
        deviceManager.$aggregateDevices
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in 
                self?.refreshAvailableOutputsIfNeeded()
                self?.updateMenu() 
            }
            .store(in: &cancellables)
        
        // Batch audio manager state changes
        Publishers.Merge3(
            audioManager.$isRunning.map { _ in () },
            audioManager.$aggregateDevice.map { _ in () },
            audioManager.$errorMessage.map { _ in () }
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self = self else { return }
            self.updateStatusIcon(isRunning: self.audioManager.isRunning)
            self.updateMenu()
            self.saveSettings()
        }
        .store(in: &cancellables)
        
        // Batch HRIR manager state changes
        Publishers.Merge3(
            hrirManager.$activePreset.map { _ in () },
            hrirManager.$convolutionEnabled.map { _ in () },
            hrirManager.$presets.map { _ in () }
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.updateMenu()
            self?.saveSettings()
        }
        .store(in: &cancellables)
    }
    
    private func waitForDevicesAndInitialize() {
        // Wait for device manager to populate devices
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            Logger.log("[MenuBarManager] Initializing settings...")
            let settings = self.loadSettings()
            self.isInitialized = true
            
            // Wait for restoration to complete before auto-starting
            DispatchQueue.main.async { [weak self] in
                self?.checkAutoStart(with: settings)
            }
        }
    }

    
    private func updateStatusIcon(isRunning: Bool) {
        if let button = statusItem.button {
            let imageName = isRunning ? "waveform.circle.fill" : "waveform.circle"
            button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "MacHRIR")
            button.image?.isTemplate = true // Allows it to adapt to dark/light mode
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }
    
    private func updateMenu() {
        menu.removeAllItems()
        
        // --- Aggregate Device Selection ---
        let deviceItemTitle = NSMenuItem(title: "Device Configuration", action: nil, keyEquivalent: "")
        deviceItemTitle.isEnabled = false
        menu.addItem(deviceItemTitle)

        let deviceMenuTitle = "Aggregate Device: \(audioManager.aggregateDevice?.name ?? "None")"
        let deviceItem = NSMenuItem(title: deviceMenuTitle, action: nil, keyEquivalent: "")
        
        let deviceMenu = NSMenu()
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        
        // Filter for valid aggregate devices (those with connected sub-devices)
        let allDevices = AudioDeviceManager.getAllDevices()
        let aggregates = allDevices.filter { device in
            guard inspector.isAggregateDevice(device) else { return false }
            
            // Only show aggregates that have at least one valid output
            return inspector.hasValidOutputs(aggregate: device)
        }
        
        if aggregates.isEmpty {
            let emptyItem = NSMenuItem(title: "No aggregate devices found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            deviceMenu.addItem(emptyItem)
        } else {
            for device in aggregates {
                let item = NSMenuItem(title: device.name, action: #selector(selectAggregateDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = (device.id == audioManager.aggregateDevice?.id) ? NSControl.StateValue.on : NSControl.StateValue.off
                deviceMenu.addItem(item)
            }
        }
        
        deviceMenu.addItem(NSMenuItem.separator())
        
        let createItem = NSMenuItem(title: "Create Aggregate Device...", action: #selector(showAggregateDeviceHelp), keyEquivalent: "")
        createItem.target = self
        deviceMenu.addItem(createItem)
        
        // --- Output Device Selection ---
        if audioManager.aggregateDevice != nil {
            let outputMenuTitle = "Output Device: \(selectedOutputDevice?.name ?? "None")"
            let outputItem = NSMenuItem(title: outputMenuTitle, action: nil, keyEquivalent: "")
            
            let outputMenu = NSMenu()
            outputItem.submenu = outputMenu
            menu.addItem(outputItem)
            
            if availableOutputs.isEmpty {
                let emptyItem = NSMenuItem(title: "No output devices in aggregate", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                outputMenu.addItem(emptyItem)
            } else {
                for output in availableOutputs {
                    let channelInfo = "Ch \(output.startChannel)-\(output.endChannel)"
                    let item = NSMenuItem(title: "\(output.name) (\(channelInfo))", action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = output
                    item.state = (output.device.id == selectedOutputDevice?.device.id) ? NSControl.StateValue.on : NSControl.StateValue.off
                    outputMenu.addItem(item)
                }
            }
        } else {
            let helpItem = NSMenuItem(title: "↑ Select aggregate device first", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // --- HRIR Configuration ---
        let hrirItem = NSMenuItem(title: "HRIR Configuration", action: nil, keyEquivalent: "")
        hrirItem.isEnabled = false
        menu.addItem(hrirItem)
        
        // Presets Submenu
        let presetsMenu = NSMenu()
        presetsMenu.minimumWidth = 200
        
        let presetsItem = NSMenuItem(title: "Preset: \(hrirManager.activePreset?.name ?? "None")", action: nil, keyEquivalent: "")
        presetsItem.submenu = presetsMenu
        menu.addItem(presetsItem)
        
        let noneItem = NSMenuItem(title: "None", action: #selector(selectPreset(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = nil
        noneItem.state = (hrirManager.activePreset == nil) ? NSControl.StateValue.on : NSControl.StateValue.off
        presetsMenu.addItem(noneItem)
        
        presetsMenu.addItem(NSMenuItem.separator())
        
        // Sort presets alphabetically by name
        let sortedPresets = hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        for preset in sortedPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = (preset.id == hrirManager.activePreset?.id) ? NSControl.StateValue.on : NSControl.StateValue.off
            presetsMenu.addItem(item)
        }
        
        let hrirFolderItem = NSMenuItem(title: "Open HRIR Folder...", action: #selector(openHRIRFolder), keyEquivalent: "")
        hrirFolderItem.target = self
        menu.addItem(hrirFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Convolution Control ---
        let convolutionItem = NSMenuItem(title: hrirManager.convolutionEnabled ? "Convolution: On" : "Convolution: Off", action: #selector(toggleConvolution), keyEquivalent: "")
        convolutionItem.target = self
        convolutionItem.state = hrirManager.convolutionEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        convolutionItem.isEnabled = (hrirManager.activePreset != nil)
        menu.addItem(convolutionItem)
        
        // --- Audio Engine Control ---
        let engineItem = NSMenuItem(title: audioManager.isRunning ? "Stop Audio Engine" : "Start Audio Engine", action: #selector(toggleAudioEngine), keyEquivalent: "")
        engineItem.target = self
        engineItem.isEnabled = (audioManager.aggregateDevice != nil && selectedOutputDevice != nil)
        menu.addItem(engineItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Application Management ---
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(title: "About MacHRIR", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        let quitItem = NSMenuItem(title: "Quit MacHRIR", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    
    private func validateAggregateDevice(_ device: AudioDevice) -> (valid: Bool, reason: String?, validOutputs: [AggregateDeviceInspector.SubDeviceInfo]?) {
        do {
            let inputs = try inspector.getInputDevices(aggregate: device)
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices for validation
            let outputs = filterAvailableOutputs(allOutputs)
            
            Logger.log("[MenuBarManager] Validation: \(inputs.count) connected inputs, \(outputs.count) connected outputs")

            if inputs.isEmpty {
                return (false, "Aggregate device '\(device.name)' has no connected input devices.\n\nPlease reconnect your input device or update the aggregate in Audio MIDI Setup.", nil)
            }

            if outputs.isEmpty {
                return (false, "Aggregate device '\(device.name)' has no connected output devices.\n\nPlease reconnect your output devices or update the aggregate in Audio MIDI Setup.", nil)
            }

            // Check for at least stereo output capability
            // Note: SubDeviceInfo now uses ranges, so we check outputChannelRange
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

    @objc private func selectAggregateDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        
        // Log device health
        let health = inspector.getDeviceHealth(aggregate: device)
        Logger.log("[MenuBarManager] Aggregate '\(device.name)': \(health.connected) connected, \(health.missing) missing")
        if health.missing > 0 {
            Logger.log("[MenuBarManager] Missing devices: \(health.missingUIDs)")
        }
        
        // Validate first
        let validation = validateAggregateDevice(device)
        if !validation.valid {
            let alert = NSAlert()
            alert.messageText = "Invalid Aggregate Device"
            alert.informativeText = validation.reason ?? "Unknown error"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        
        audioManager.selectAggregateDevice(device)
        
        // Load available outputs (already validated and filtered)
        availableOutputs = validation.validOutputs ?? []
        
        do {
            // Auto-select first output if available
            if let firstOutput = availableOutputs.first {
                selectedOutputDevice = firstOutput
                lastUserSelectedOutputUID = firstOutput.uid  // Track this selection
                
                // Setup audio graph with aggregate
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: firstOutput.stereoChannelRange
                )
            } else {
                selectedOutputDevice = nil
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
        
        updateMenu()
    }
    
    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else { return }
        
        selectedOutputDevice = output
        lastUserSelectedOutputUID = output.uid  // Track user's choice
        
        // Update output routing (NO NEED TO STOP AUDIO!)
        let channelRange = output.stereoChannelRange
        audioManager.setOutputChannels(channelRange)
        
        updateMenu()
        saveSettings()
    }
    
    @objc private func showAggregateDeviceHelp() {
        // Open Audio MIDI Setup
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        
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
    
    @objc private func selectPreset(_ sender: NSMenuItem) {
        let preset = sender.representedObject as? HRIRPreset
        
        if let preset = preset {
            // Use current sample rate or default
            let sampleRate = 48000.0 // We should get this from the device if possible, but for now default is safe
            let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        } else {
            // Handle "None"
            hrirManager.activePreset = nil
        }
    }
    
    @objc private func openHRIRFolder() {
        hrirManager.openPresetsDirectory()
    }
    
    @objc private func toggleConvolution() {
        hrirManager.convolutionEnabled.toggle()
    }
    
    @objc private func toggleAudioEngine() {
        if audioManager.isRunning {
            audioManager.stop()
        } else {
            audioManager.start()
        }
    }
    
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    
    @objc private func showSettings() {
        SettingsWindowController.shared.showSettings()
    }
    
    @objc private func quitApp() {
        // Cancel debounce timer and save immediately
        saveDebounceTimer?.invalidate()
        performSave()
        audioManager.stop()
        NSApp.terminate(nil)
    }
    
    // MARK: - Persistence
    
    @discardableResult
    private func loadSettings() -> AppSettings {
        Logger.log("[MenuBarManager] Loading settings...")
        isRestoringState = true
        
        let settings = settingsManager.loadSettings()
        
        // Restore aggregate device
        if let deviceUID = settings.aggregateDeviceUID,
           let device = AudioDeviceManager.getDeviceByUID(deviceUID),
           inspector.isAggregateDevice(device) {
            
            Logger.log("[MenuBarManager] Restoring aggregate device: \(device.name)")
            audioManager.selectAggregateDevice(device)
            
            // Load available outputs
            do {
                let allOutputs = try inspector.getOutputDevices(aggregate: device)
                
                // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
                availableOutputs = filterAvailableOutputs(allOutputs)
                
                // Restore selected output device
                if let outputUID = settings.selectedOutputDeviceUID,
                   let output = availableOutputs.first(where: { $0.uid == outputUID }) {
                    selectedOutputDevice = output
                    lastUserSelectedOutputUID = output.uid  // Track restored selection
                } else if let firstOutput = availableOutputs.first {
                    // Fallback to first output
                    selectedOutputDevice = firstOutput
                    lastUserSelectedOutputUID = firstOutput.uid  // Track fallback selection
                }
                
                // Setup audio graph
                if let output = selectedOutputDevice {
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
            Logger.log("[MenuBarManager] Restoring preset: \(preset.name)")
            let sampleRate = 48000.0
            let inputLayout = InputLayout.detect(channelCount: 2)
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        }
        
        // Restore convolution
        Logger.log("[MenuBarManager] Restoring convolution: \(settings.convolutionEnabled)")
        hrirManager.convolutionEnabled = settings.convolutionEnabled
        
        // Allow observers to fire before enabling saves
        DispatchQueue.main.async { [weak self] in
            self?.isRestoringState = false
            Logger.log("[MenuBarManager] Restoration complete, saves now enabled")
        }
        
        return settings
    }
    
    private func saveSettings() {
        guard isInitialized && !isRestoringState else {
            Logger.log("[MenuBarManager] Skipping save (Initialized: \(isInitialized), Restoring: \(isRestoringState))")
            return
        }
        
        // Debounce saves
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.performSave()
        }
    }
    
    private func performSave() {
        Logger.log("[MenuBarManager] Saving settings...")

        // Get UIDs for persistence
        let aggregateUID = audioManager.aggregateDevice?.uid
        let outputUID = selectedOutputDevice?.uid

        let settings = AppSettings(
            aggregateDeviceID: nil,  // Deprecated, leave nil
            selectedOutputDeviceID: nil,  // Deprecated, leave nil
            aggregateDeviceUID: aggregateUID,
            selectedOutputDeviceUID: outputUID,
            activePresetID: hrirManager.activePreset?.id,
            convolutionEnabled: hrirManager.convolutionEnabled,
            autoStart: audioManager.isRunning,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
        settingsManager.saveSettings(settings)
    }
    
    private func checkAutoStart(with settings: AppSettings) {
        if settings.autoStart && audioManager.aggregateDevice != nil && selectedOutputDevice != nil {
            Logger.log("[MenuBarManager] Auto-starting audio engine...")
            audioManager.start()
        }
    }
    
    deinit {
        removeAggregateDeviceListener()
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
        
        let status = AudioObjectAddPropertyListener(
            device.id,
            &propertyAddress,
            aggregateDeviceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        if status == noErr {
            aggregateListenerAdded = true
            currentMonitoredAggregate = device
            Logger.log("[MenuBarManager] Added listener for aggregate device: \(device.name)")
        } else {
            Logger.log("[MenuBarManager] Failed to add aggregate listener, status: \(status)")
        }
    }
    
    private func removeAggregateDeviceListener() {
        guard aggregateListenerAdded, let device = currentMonitoredAggregate else {
            return
        }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            device.id,
            &propertyAddress,
            aggregateDeviceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        aggregateListenerAdded = false
        currentMonitoredAggregate = nil
        Logger.log("[MenuBarManager] Removed aggregate device listener")
    }
    
    /// Helper to filter out virtual loopback devices
    private func filterAvailableOutputs(_ allOutputs: [AggregateDeviceInspector.SubDeviceInfo]) -> [AggregateDeviceInspector.SubDeviceInfo] {
        // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
        // These are input-only virtual devices that users never want to output to
        var filtered = allOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }
        
        // Handle case where all outputs were filtered
        if filtered.isEmpty && !allOutputs.isEmpty {
            Logger.log("[MenuBarManager] Warning: All outputs were virtual loopback devices, showing all")
            filtered = allOutputs
        }
        
        return filtered
    }

    /// Refresh available outputs if we have an aggregate device selected
    /// Called when system device list changes (devices added/removed)
    fileprivate func refreshAvailableOutputsIfNeeded() {
        guard let device = audioManager.aggregateDevice else { return }
        
        do {
            let previousCount = availableOutputs.count
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
            availableOutputs = filterAvailableOutputs(allOutputs)
            
            if availableOutputs.count != previousCount {
                Logger.log("[MenuBarManager] Output count changed: \(previousCount) -> \(availableOutputs.count)")
                
                // Try to restore user's preferred device
                restoreUserPreferredDevice(from: availableOutputs)
                
                updateMenu()
            }
        } catch {
            Logger.log("[MenuBarManager] Failed to refresh outputs: \(error)")
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
            let needsAudioUnitReset = selectedOutputDevice?.device.id != preferredDevice.device.id
            
            if needsAudioUnitReset {
                restoreDeviceAfterReconnection(preferredDevice)
            } else {
                refreshChannelMapping(for: preferredDevice)
            }
        }
        // Priority 2: Check if current selection still exists
        else if let currentOutput = selectedOutputDevice {
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
            Logger.log("[MenuBarManager] Auto-selecting first available output: \(firstOutput.name)")
            selectedOutputDevice = firstOutput
            lastUserSelectedOutputUID = firstOutput.uid
            
            let channelRange = firstOutput.stereoChannelRange
            audioManager.setOutputChannels(channelRange)
            
            updateMenu()
        }
    }
    
    private func restoreDeviceAfterReconnection(_ device: AggregateDeviceInspector.SubDeviceInfo) {
        Logger.log("[MenuBarManager] Restoring reconnected device: \(device.name)")
        
        guard let aggregate = audioManager.aggregateDevice else { return }
        
        let wasRunning = audioManager.isRunning
        if wasRunning { audioManager.stop() }
        
        do {
            try audioManager.setupAudioUnit(
                aggregateDevice: aggregate,
                outputChannelRange: device.stereoChannelRange
            )
            
            selectedOutputDevice = device
            
            if wasRunning { audioManager.start() }
            
            Logger.log("[MenuBarManager] ✅ Restored: \(device.name)")
        } catch {
            Logger.log("[MenuBarManager] ❌ Failed to restore: \(error)")
        }
    }
    
    private func refreshChannelMapping(for device: AggregateDeviceInspector.SubDeviceInfo) {
        // Only log if channels actually changed
        if selectedOutputDevice?.startChannel != device.startChannel {
            Logger.log("[MenuBarManager] Refreshing channel mapping for: \(device.name) (ch \(device.startChannel)-\(device.startChannel + 1))")
        }
        
        selectedOutputDevice = device
        let channelRange = device.stereoChannelRange
        audioManager.setOutputChannels(channelRange)
    }
    
    private func handleOutputDeviceDisconnected() {
        Logger.log("[MenuBarManager] Currently-selected output was disconnected")
        
        // Capture running state BEFORE stopping
        let wasRunning = audioManager.isRunning
        
        if wasRunning {
            audioManager.stop()
        }
        
        // Try to select first available output
        if let firstAvailable = availableOutputs.first {
            selectedOutputDevice = firstAvailable
            
            do {
                if let aggregate = audioManager.aggregateDevice {
                    try audioManager.setupAudioUnit(
                        aggregateDevice: aggregate,
                        outputChannelRange: firstAvailable.stereoChannelRange
                    )
                    Logger.log("[MenuBarManager] Switched to fallback output: \(firstAvailable.name)")
                    
                    // NEW: Restart audio if it was running
                    if wasRunning {
                        audioManager.start()
                        Logger.log("[MenuBarManager] ✅ Audio engine restarted on fallback device")
                    }
                }
            } catch {
                Logger.log("[MenuBarManager] Failed to switch to fallback output: \(error)")
            }
        } else {
            // No outputs available
            selectedOutputDevice = nil
            Logger.log("[MenuBarManager] No outputs available after disconnect")
        }
        
        updateMenu()
    }
}

// MARK: - Core Audio Callbacks

/// Callback for aggregate device configuration changes
private func aggregateDeviceChangeCallback(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else {
        return noErr
    }
    
    let manager = Unmanaged<MenuBarManager>.fromOpaque(clientData).takeUnretainedValue()
    
    // Handle on main thread
    DispatchQueue.main.async {
        manager.refreshAvailableOutputsIfNeeded()
    }
    
    return noErr
}
