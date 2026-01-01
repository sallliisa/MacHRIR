//
//  SettingsView.swift
//  Airwave
//
//  Shows a checklist of setup requirements for the app
//

import SwiftUI
import AppKit
private typealias PlatformColor = NSColor
import AppKit
import CoreAudio

struct SettingsView: View {
    // Shared singleton instances - not owned by this view
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var audioManager = AudioGraphManager.shared
    @ObservedObject private var deviceManager = AudioDeviceManager.shared
    
    // Inspector for aggregate device info
    private let inspector = AggregateDeviceInspector()
    
    // Static UUID for "None" option in HRIR picker
    private static let nonePresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status Card (at the very top)
                overallStatusCard
                
                // General Settings
                generalSection

                // Application Settings
                applicationSection
                
                // Diagnostics
                checklistSection
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 500, maxWidth: 500)
        .frame(minHeight: 400, idealHeight: 560)
        .onAppear {
            refreshAvailableOutputs()
            diagnosticsManager.refresh()
        }
        .onChange(of: audioManager.aggregateDevice?.id) {
            refreshAvailableOutputs()
        }
    }
    
    // MARK: - Subviews
    
    private var overallStatusCard: some View {
        let diagnostics = diagnosticsManager.diagnostics
        let isFullyConfigured = diagnostics.isFullyConfigured
        let isRunning = audioManager.isRunning
        let hasAggregateDevice = audioManager.aggregateDevice != nil
        let hasOutputDevice = audioManager.selectedOutputDevice != nil
        
        // Determine state:
        // WARNING: Diagnostics not fulfilled
        // INFO: Ready to run but not running (engine off, no aggregate/output device selected)
        // RUNNING: Actually running
        let (statusIcon, statusColor, statusTitle, statusMessage) = getStatusInfo(
            isFullyConfigured: isFullyConfigured,
            isRunning: isRunning,
            hasAggregateDevice: hasAggregateDevice,
            hasOutputDevice: hasOutputDevice
        )
        
        return HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(statusColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(statusColor.opacity(0.3), lineWidth: 0.5)
        )
    }
    
    private func getStatusInfo(
        isFullyConfigured: Bool,
        isRunning: Bool,
        hasAggregateDevice: Bool,
        hasOutputDevice: Bool
    ) -> (icon: String, color: Color, title: String, message: String) {
        // WARNING: Diagnostics not fulfilled
        if !isFullyConfigured {
            return (
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Setup Required",
                message: "Some setup steps need to be completed before using Airwave."
            )
        }
        
        // RUNNING: Actually running
        if isRunning && hasAggregateDevice && hasOutputDevice {
            return (
                icon: "checkmark.seal.fill",
                color: .green,
                title: "Running",
                message: "Audio engine is active and processing audio."
            )
        }
        
        // INFO: Ready to run but not running
        return (
            icon: "info.circle.fill",
            color: .blue,
            title: "Ready to Use",
            message: "All requirements are met. Airwave is ready for audio processing."
        )
    }
    
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            
            VStack(spacing: 0) {
                // Aggregate Device Selector
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Aggregate Device")
                            .font(.system(size: 12))
                        Text(audioManager.aggregateDevice?.name ?? "Select an aggregate device")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if validAggregateDevices.isEmpty {
                        Text("No aggregate devices found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { audioManager.aggregateDevice?.id ?? validAggregateDevices.first?.id },
                            set: { newID in
                                if let newID = newID,
                                   let device = validAggregateDevices.first(where: { $0.id == newID }) {
                                    selectAggregateDevice(device)
                                }
                            }
                        )) {
                            ForEach(validAggregateDevices, id: \.id) { device in
                                Text(device.name).tag(device.id as AudioDeviceID?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                // Output Device Selector (only shown when aggregate is selected)
                if audioManager.aggregateDevice != nil {
                    Divider().padding(.leading, 30)
                    
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Output Device")
                                .font(.system(size: 12))
                            Text(audioManager.selectedOutputDevice?.name ?? "Select an output device")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if audioManager.availableOutputs.isEmpty {
                            Text("No devices in aggregate")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: Binding(
                                get: { audioManager.selectedOutputDevice?.device.id ?? audioManager.availableOutputs.first?.device.id },
                                set: { newID in
                                    if let newID = newID,
                                       let output = audioManager.availableOutputs.first(where: { $0.device.id == newID }) {
                                        selectOutputDevice(output)
                                    }
                                }
                            )) {
                                ForEach(audioManager.availableOutputs, id: \.device.id) { output in
                                    let channelInfo = "Ch \(output.startChannel)-\(output.endChannel)"
                                    Text("\(output.name) (\(channelInfo))").tag(output.device.id as AudioDeviceID?)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                
                Divider().padding(.leading, 30)

                // HRIR Preset Selector
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HRIR Preset")
                            .font(.system(size: 12))
                        HStack(spacing: 4) {
                            Text("Select spatial audio profile •")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button(action: {
                                hrirManager.openPresetsDirectory()
                            }) {
                                Text("Manage files")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Spacer()
                    
                    if hrirManager.presets.isEmpty {
                        Text("No HRIR files found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { hrirManager.activePreset?.id ?? Self.nonePresetID },
                            set: { newID in
                                if let preset = hrirManager.presets.first(where: { $0.id == newID }) {
                                    let sampleRate = 48000.0
                                    let inputLayout = InputLayout.detect(channelCount: 2)
                                    hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                                } else {
                                    hrirManager.activePreset = nil
                                }
                            }
                        )) {
                            Text("None").tag(Self.nonePresetID)
                            ForEach(hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider().padding(.leading, 30)

                // Audio Engine Toggle
                HStack(spacing: 10) {
                    Image(audioManager.isRunning ? "MenuBarIconFilled" : "MenuBarIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Audio Engine")
                            .font(.system(size: 12))
                        if !diagnosticsManager.diagnostics.isFullyConfigured {
                            Text("Complete diagnostics setup to continue")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else if audioManager.aggregateDevice == nil {
                            Text("Select a device to continue")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else {
                            Text(audioManager.isRunning ? "Processing audio" : "Stopped")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { audioManager.isRunning },
                        set: { shouldRun in
                            if shouldRun {
                                audioManager.start()
                            } else {
                                audioManager.stop()
                            }
                        }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!diagnosticsManager.diagnostics.isFullyConfigured || audioManager.aggregateDevice == nil)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(6)
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Application")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                // Run on Startup
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Run on Startup")
                            .font(.system(size: 12))
                        Text("Start Airwave automatically when you log in")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(6)
        }
    }
    
    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: {
                    diagnosticsManager.refresh()
                }) {
                    HStack(spacing: 4) {
                        if diagnosticsManager.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text("Refresh")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(diagnosticsManager.isRefreshing)
            }
            .padding(.bottom, 8)

            // Help Section
            helpSection
                .padding(.bottom, 8)
            
            VStack(spacing: 0) {
                // Virtual Audio Driver
                ChecklistRow(
                    title: "Virtual Audio Driver",
                    subtitle: diagnosticsManager.diagnostics.virtualDriverInstalled
                        ? diagnosticsManager.diagnostics.detectedVirtualDrivers.joined(separator: ", ")
                        : "BlackHole, Loopback, or Soundflower",
                    status: diagnosticsManager.diagnostics.virtualDriverInstalled ? .complete : .missing,
                    actionTitle: diagnosticsManager.diagnostics.virtualDriverInstalled ? nil : "Install BlackHole",
                    action: {
                        if let url = URL(string: "https://existential.audio/blackhole/") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    secondaryActionTitle: "Setup Guide",
                    secondaryAction: {
                        if let url = URL(string: "https://github.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                
                Divider().padding(.leading, 30)
                
                // Aggregate Device
                ChecklistRow(
                    title: "Aggregate Device",
                    subtitle: aggregateSubtitle,
                    status: aggregateStatus,
                    actionTitle: diagnosticsManager.diagnostics.validAggregateExists ? nil : "Open Audio MIDI Setup",
                    action: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    },
                    secondaryActionTitle: "Configure...",
                    secondaryAction: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    }
                )
                
                Divider().padding(.leading, 30)
                
                // Microphone Permission
                ChecklistRow(
                    title: "Microphone Permission",
                    subtitle: micPermissionSubtitle,
                    status: micPermissionStatus,
                    secondaryActionTitle: "Configure...",
                    secondaryAction: {
                        PermissionManager.shared.openSystemSettings()
                    }
                )
            }
            .background(.ultraThinMaterial)
            .cornerRadius(6)
        }
    }
    
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Need Help?")
                .font(.system(size: 12, weight: .semibold))
            
            Text("Airwave requires a virtual audio driver (like BlackHole) and an aggregate device that combines it with your output device. This allows system audio to be processed through HRIR convolution before reaching your headphones.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
    }
    
    // MARK: - Computed Properties
    
    private var aggregateSubtitle: String {
        let d = diagnosticsManager.diagnostics
        if d.validAggregateExists {
            return "\(d.aggregateCount) configured"
        } else if d.aggregateDevicesExist {
            return "Found but needs input + output devices"
        } else {
            return "Create in Audio MIDI Setup"
        }
    }
    
    private var aggregateStatus: ChecklistStatus {
        let d = diagnosticsManager.diagnostics
        if d.validAggregateExists {
            return .complete
        } else if d.aggregateDevicesExist {
            return .warning
        } else {
            return .missing
        }
    }
    
    private var micPermissionSubtitle: String {
        let d = diagnosticsManager.diagnostics
        if d.microphonePermissionGranted {
            return "Granted"
        } else if d.microphonePermissionDetermined {
            return "Denied - open System Settings to enable"
        } else {
            return "Not yet requested"
        }
    }
    
    private var micPermissionStatus: ChecklistStatus {
        let d = diagnosticsManager.diagnostics
        if d.microphonePermissionGranted {
            return .complete
        } else if d.microphonePermissionDetermined {
            return .missing
        } else {
            return .warning
        }
    }
    
    // MARK: - Device Selection
    
    /// Filter for valid aggregate devices (those with connected sub-devices)
    private var validAggregateDevices: [AudioDevice] {
        deviceManager.aggregateDevices.filter { device in
            inspector.hasValidOutputs(aggregate: device)
        }
    }
    
    /// Select an aggregate device and configure outputs
    private func selectAggregateDevice(_ device: AudioDevice) {
        // Stop audio if running
        let wasRunning = audioManager.isRunning
        if wasRunning {
            audioManager.stop()
        }
        
        audioManager.selectAggregateDevice(device)
        
        // Load available outputs
        do {
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices
            audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
            
            // Auto-select first output if available
            if let firstOutput = audioManager.availableOutputs.first {
                audioManager.selectedOutputDevice = firstOutput
                
                // Setup audio graph
                try audioManager.setupAudioUnit(
                    aggregateDevice: device,
                    outputChannelRange: firstOutput.stereoChannelRange
                )
            } else {
                audioManager.selectedOutputDevice = nil
            }
            
            // Restart if was running
            if wasRunning && audioManager.selectedOutputDevice != nil {
                audioManager.start()
            }
            
        } catch {
            Logger.log("Failed to configure aggregate device: \(error)")
        }
    }
    
    /// Select an output device
    private func selectOutputDevice(_ output: AggregateDeviceInspector.SubDeviceInfo) {
        audioManager.selectedOutputDevice = output
        
        // Update output routing without stopping audio
        let channelRange = output.stereoChannelRange
        audioManager.setOutputChannels(channelRange)
    }
    
    /// Refresh available outputs from current aggregate device
    private func refreshAvailableOutputs() {
        guard let device = audioManager.aggregateDevice else {
            audioManager.availableOutputs = []
            audioManager.selectedOutputDevice = nil
            return
        }
        
        do {
            let allOutputs = try inspector.getOutputDevices(aggregate: device)
            
            // Filter out virtual loopback devices
            audioManager.availableOutputs = filterAvailableOutputs(allOutputs)
            
            // Try to maintain current selection if it still exists
            if let currentOutput = audioManager.selectedOutputDevice,
               let stillExists = audioManager.availableOutputs.first(where: { $0.device.id == currentOutput.device.id }) {
                audioManager.selectedOutputDevice = stillExists
            } else if let firstOutput = audioManager.availableOutputs.first {
                // Auto-select first output if current selection is gone
                audioManager.selectedOutputDevice = firstOutput
            } else {
                audioManager.selectedOutputDevice = nil
            }
            
        } catch {
            Logger.log("Failed to refresh outputs: \(error)")
            audioManager.availableOutputs = []
            audioManager.selectedOutputDevice = nil
        }
    }
    
    /// Filter out virtual loopback devices (BlackHole, Soundflower, etc.)
    private func filterAvailableOutputs(_ allOutputs: [AggregateDeviceInspector.SubDeviceInfo]) -> [AggregateDeviceInspector.SubDeviceInfo] {
        return allOutputs.filter { output in
            let name = output.name.lowercased()
            return !name.contains("blackhole") && !name.contains("soundflower")
        }
    }
}

// MARK: - Supporting Types

enum ChecklistStatus {
    case complete
    case warning
    case missing
    
    var color: Color {
        switch self {
        case .complete: return .green
        case .warning: return .orange
        case .missing: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .complete: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }
}

// MARK: - Checklist Row

struct ChecklistRow: View {
    let title: String
    let subtitle: String
    let status: ChecklistStatus
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon)
                .font(.system(size: 13))
                .foregroundStyle(status.color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Secondary action button (always shown if provided)
            if let secondaryActionTitle = secondaryActionTitle, let secondaryAction = secondaryAction {
                Button(secondaryActionTitle) {
                    secondaryAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }
            
            // Primary action button (conditional)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Aggregate Device Row

struct AggregateDeviceRow: View {
    let health: AggregateHealth
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: health.isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(health.isValid ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(health.name)
                    .font(.system(size: 13, weight: .medium))
                
                HStack(spacing: 8) {
                    Label("\(health.inputDeviceCount) input", systemImage: "mic.fill")
                    Label("\(health.outputDeviceCount) output", systemImage: "speaker.wave.2.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                if !health.missingDevices.isEmpty {
                    Text("Missing: \(health.missingDevices.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

#Preview {
    SettingsView()
}
