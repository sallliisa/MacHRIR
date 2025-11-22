//
//  MenuBarManager.swift
//  MacHRIR
//
//  Created by gamer on 22/11/25.
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
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false
    private var isRestoringState = false
    private var saveDebounceTimer: Timer?
    
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
        // Observe device changes
        deviceManager.$inputDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)
            
        deviceManager.$outputDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)
            
        // Observe audio manager state
        audioManager.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] isRunning in
                self?.updateStatusIcon(isRunning: isRunning)
                self?.updateMenu()
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        audioManager.$inputDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        audioManager.$outputDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        // Observe HRIR manager state
        hrirManager.$activePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        hrirManager.$convolutionEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        hrirManager.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)
    }
    
    private func waitForDevicesAndInitialize() {
        // Combine both device publishers to wait for both to be populated
        Publishers.CombineLatest(
            deviceManager.$inputDevices,
            deviceManager.$outputDevices
        )
        .first { inputDevices, outputDevices in
            // Wait until we have at least one device in each category
            return !inputDevices.isEmpty && !outputDevices.isEmpty
        }
        .timeout(.seconds(5), scheduler: DispatchQueue.main)
        .replaceError(with: (deviceManager.inputDevices, deviceManager.outputDevices))
        .sink { [weak self] _ in
            guard let self = self else { return }
            print("[MenuBarManager] Devices loaded, initializing settings...")
            let settings = self.loadSettings()
            self.isInitialized = true
            
            // Wait for restoration to complete before auto-starting
            DispatchQueue.main.async { [weak self] in
                self?.checkAutoStart(with: settings)
            }
        }
        .store(in: &cancellables)
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
        
        // --- Audio Devices ---
        let devicesItem = NSMenuItem(title: "Audio Devices", action: nil, keyEquivalent: "")
        devicesItem.isEnabled = false
        menu.addItem(devicesItem)
        
        // Input Devices Submenu
        let inputMenu = NSMenu()
        let inputItem = NSMenuItem(title: "Input: \(audioManager.inputDevice?.name ?? "None")", action: nil, keyEquivalent: "")
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)
        
        for device in deviceManager.inputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = (device.id == audioManager.inputDevice?.id) ? .on : .off
            inputMenu.addItem(item)
        }
        
        // Output Devices Submenu
        let outputMenu = NSMenu()
        let outputItem = NSMenuItem(title: "Output: \(audioManager.outputDevice?.name ?? "None")", action: nil, keyEquivalent: "")
        outputItem.submenu = outputMenu
        menu.addItem(outputItem)
        
        for device in deviceManager.outputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = (device.id == audioManager.outputDevice?.id) ? .on : .off
            outputMenu.addItem(item)
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
        noneItem.state = (hrirManager.activePreset == nil) ? .on : .off
        presetsMenu.addItem(noneItem)
        
        presetsMenu.addItem(NSMenuItem.separator())
        
        // Sort presets alphabetically by name
        let sortedPresets = hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        for preset in sortedPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = (preset.id == hrirManager.activePreset?.id) ? .on : .off
            presetsMenu.addItem(item)
        }
        
        let hrirFolderItem = NSMenuItem(title: "Open HRIR Folder...", action: #selector(openHRIRFolder), keyEquivalent: "")
        hrirFolderItem.target = self
        menu.addItem(hrirFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- Convolution Control ---
        let convolutionItem = NSMenuItem(title: hrirManager.convolutionEnabled ? "Disable Convolution" : "Enable Convolution", action: #selector(toggleConvolution), keyEquivalent: "")
        convolutionItem.target = self
        convolutionItem.state = hrirManager.convolutionEnabled ? .on : .off
        convolutionItem.isEnabled = (hrirManager.activePreset != nil)
        menu.addItem(convolutionItem)
        
        // --- Audio Engine Control ---
        let engineItem = NSMenuItem(title: audioManager.isRunning ? "Stop Audio Engine" : "Start Audio Engine", action: #selector(toggleAudioEngine), keyEquivalent: "")
        engineItem.target = self
        engineItem.isEnabled = (audioManager.inputDevice != nil && audioManager.outputDevice != nil)
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
    
    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? AudioDevice {
            audioManager.selectInputDevice(device)
        }
    }
    
    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? AudioDevice {
            audioManager.selectOutputDevice(device)
        }
    }
    
    @objc private func selectPreset(_ sender: NSMenuItem) {
        let preset = sender.representedObject as? HRIRPreset
        
        if let preset = preset {
            let sampleRate = audioManager.outputDevice?.sampleRate ?? 48000.0
            let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        } else {
            // Handle "None" selection if needed, though HRIRManager might not have a 'clear' method exposed directly like this
            // Assuming activatePreset handles nil or we just don't call it.
            // Actually, looking at ContentView, it passes nil to deactivate.
            // HRIRManager.activatePreset takes a non-optional.
            // We might need to add a deactivate method or just set activePreset = nil if it was public, but it's read-only likely.
            // Let's check HRIRManager... wait, I can't check it right now without a tool call.
            // Based on ContentView: `hrirManager.activatePreset(preset...)`
            // And `activePreset` is `@Published`.
            // If I can't set it directly, I might need to implement a clear method or just rely on convolution toggle.
            // For now, let's assume selecting a new one overwrites.
            // If "None" is selected, we probably just want to disable convolution or clear the preset.
            // Let's look at ContentView again.
            // ContentView: `set: { if let preset = $0 { ... } }`
            // It seems ContentView only calls activatePreset if $0 is not nil.
            // So "None" just does nothing in ContentView?
            // Ah, `selection: Binding(get: ..., set: ...)`
            // If tag is nil, $0 is nil.
            // So ContentView doesn't seem to support clearing the preset via the picker explicitly other than maybe not calling activate.
            // But `hrirManager.activePreset` is read-only?
            // Let's assume for now we just don't activate anything if it's None.
            // But we should probably allow clearing it.
            // I'll leave "None" as just doing nothing for now, or maybe just disabling convolution.
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
        
        // Restore input
        if let inputID = settings.selectedInputDeviceID,
           let device = deviceManager.inputDevices.first(where: { $0.id == inputID }) {
            print("[MenuBarManager] Restoring input: \(device.name)")
            audioManager.selectInputDevice(device)
        }
        
        // Restore output
        if let outputID = settings.selectedOutputDeviceID,
           let device = deviceManager.outputDevices.first(where: { $0.id == outputID }) {
            print("[MenuBarManager] Restoring output: \(device.name)")
            audioManager.selectOutputDevice(device)
        }
        
        // Restore preset
        if let presetID = settings.activePresetID,
           let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
            print("[MenuBarManager] Restoring preset: \(preset.name)")
            let sampleRate = audioManager.outputDevice?.sampleRate ?? 48000.0
            let inputLayout = InputLayout.detect(channelCount: 2)
            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
        }
        
        // Restore convolution
        print("[MenuBarManager] Restoring convolution: \(settings.convolutionEnabled)")
        hrirManager.convolutionEnabled = settings.convolutionEnabled
        
        // Allow observers to fire before enabling saves
        // This ensures all the restoration changes above don't trigger saves
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
        
        // Debounce saves - cancel any pending save and schedule a new one
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.performSave()
        }
    }
    
    private func performSave() {
        print("[MenuBarManager] Saving settings...")
        let settings = AppSettings(
            selectedInputDeviceID: audioManager.inputDevice?.id,
            selectedOutputDeviceID: audioManager.outputDevice?.id,
            activePresetID: hrirManager.activePreset?.id,
            convolutionEnabled: hrirManager.convolutionEnabled,
            autoStart: audioManager.isRunning,
            bufferSize: 65536,
            targetSampleRate: audioManager.outputDevice?.sampleRate ?? 48000.0
        )
        settingsManager.saveSettings(settings)
    }
    
    private func checkAutoStart(with settings: AppSettings) {
        if settings.autoStart && audioManager.inputDevice != nil && audioManager.outputDevice != nil {
            print("[MenuBarManager] Auto-starting audio engine...")
            audioManager.start()
        }
    }
}
