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
    
    override init() {
        super.init()
        
        // Connect managers
        audioManager.hrirManager = hrirManager
        
        setupStatusItem()
        setupObservers()
        
        // Wait for devices to populate before loading settings
        waitForDevicesAndInitialize()
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
        // Watch for aggregate device list changes
        deviceManager.$aggregateDevices
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenu() }
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
            print("[MenuBarManager] Initializing settings...")
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
        let deviceMenuTitle = "Aggregate Device: \(audioManager.aggregateDevice?.name ?? "None")"
        let deviceItem = NSMenuItem(title: deviceMenuTitle, action: nil, keyEquivalent: "")
        
        let deviceMenu = NSMenu()
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        
        // Filter for valid aggregate devices (those with sub-devices)
        let allDevices = AudioDeviceManager.getAllDevices()
        let aggregates = allDevices.filter { inspector.isAggregateDevice($0) }
        
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
        
        // Status indicator
        if let output = selectedOutputDevice {
            let statusItem = NSMenuItem(title: "→ Playing to: \(output.name)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
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
        let aboutItem = NSMenuItem(title: "About MacHRIR", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        let quitItem = NSMenuItem(title: "Quit MacHRIR", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    
    @objc private func selectAggregateDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        
        audioManager.selectAggregateDevice(device)
        
        // Load available outputs
        do {
            availableOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Auto-select first output if available
            if let firstOutput = availableOutputs.first {
                selectedOutputDevice = firstOutput
                
                // Setup audio graph with aggregate
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: firstOutput.startChannel..<(firstOutput.startChannel + 2)
                )
            } else {
                selectedOutputDevice = nil
            }
            
            // Restart if was running
            if wasRunning {
                audioManager.start()
            }
            
        } catch {
            print("Failed to configure aggregate device: \(error)")
        }
        
        updateMenu()
    }
    
    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let output = sender.representedObject as? AggregateDeviceInspector.SubDeviceInfo else { return }
        
        selectedOutputDevice = output
        
        // Update output routing (NO NEED TO STOP AUDIO!)
        let channelRange = output.startChannel..<(output.startChannel + 2)
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
        print("[MenuBarManager] Loading settings...")
        isRestoringState = true
        
        let settings = settingsManager.loadSettings()
        
        // Restore aggregate device
        if let deviceID = settings.aggregateDeviceID,
           let device = AudioDeviceManager.getAllDevices().first(where: { $0.id == deviceID }),
           inspector.isAggregateDevice(device) {
            
            print("[MenuBarManager] Restoring aggregate device: \(device.name)")
            audioManager.selectAggregateDevice(device)
            
            // Load available outputs
            do {
                availableOutputs = try inspector.getOutputDevices(aggregate: device)
                
                // Restore selected output device
                if let outputID = settings.selectedOutputDeviceID,
                   let output = availableOutputs.first(where: { $0.device.id == outputID }) {
                    selectedOutputDevice = output
                } else if let firstOutput = availableOutputs.first {
                    // Fallback to first output
                    selectedOutputDevice = firstOutput
                }
                
                // Setup audio graph
                if let output = selectedOutputDevice {
                    try audioManager.setupAudioUnit(
                        aggregateDevice: device,
                        outputChannelRange: output.startChannel..<(output.startChannel + 2)
                    )
                }
                
            } catch {
                print("Failed to restore audio configuration: \(error)")
            }
        }
        
        // Restore preset
        if let presetID = settings.activePresetID,
           let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
            print("[MenuBarManager] Restoring preset: \(preset.name)")
            let sampleRate = 48000.0
            let inputLayout = InputLayout.detect(channelCount: 2)
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        }
        
        // Restore convolution
        print("[MenuBarManager] Restoring convolution: \(settings.convolutionEnabled)")
        hrirManager.convolutionEnabled = settings.convolutionEnabled
        
        // Allow observers to fire before enabling saves
        DispatchQueue.main.async { [weak self] in
            self?.isRestoringState = false
            print("[MenuBarManager] Restoration complete, saves now enabled")
        }
        
        return settings
    }
    
    private func saveSettings() {
        guard isInitialized && !isRestoringState else {
            print("[MenuBarManager] Skipping save (Initialized: \(isInitialized), Restoring: \(isRestoringState))")
            return
        }
        
        // Debounce saves
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.performSave()
        }
    }
    
    private func performSave() {
        print("[MenuBarManager] Saving settings...")
        let settings = AppSettings(
            aggregateDeviceID: audioManager.aggregateDevice?.id,
            selectedOutputDeviceID: selectedOutputDevice?.device.id,
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
            print("[MenuBarManager] Auto-starting audio engine...")
            audioManager.start()
        }
    }
}
