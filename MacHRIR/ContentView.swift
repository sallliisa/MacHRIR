//
//  ContentView.swift
//  MacHRIR
//
//  Main application interface
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioManager = AudioGraphManager()
    @StateObject private var hrirManager = HRIRManager()
    @State private var settingsManager = SettingsManager()

    @State private var inputDevices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []

    @State private var showingError = false
    @State private var isInitialized = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                Text("MacHRIR")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.top)

            Divider()

            // Device Selection Section
            VStack(alignment: .leading, spacing: 15) {
                Text("Audio Devices")
                    .font(.headline)

                // Input Device Selector
                HStack {
                    Picker("Input Device", selection: Binding(
                        get: { audioManager.inputDevice },
                        set: { if let device = $0 { audioManager.selectInputDevice(device) } }
                    )) {
                        Text("Select Input...").tag(nil as AudioDevice?)
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .frame(width: 300)
                }

                // Output Device Selector
                HStack {
                    Picker("Output Device", selection: Binding(
                        get: { audioManager.outputDevice },
                        set: { if let device = $0 { audioManager.selectOutputDevice(device) } }
                    )) {
                        Text("Select Output...").tag(nil as AudioDevice?)
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(device as AudioDevice?)
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)

            Divider()

            // HRIR Preset Section
            VStack(alignment: .leading, spacing: 15) {
                Text("HRIR Presets")
                    .font(.headline)

                HStack {
                    Picker("Preset", selection: Binding(
                        get: { hrirManager.activePreset },
                        set: { if let preset = $0 {
                            let sampleRate = audioManager.outputDevice?.sampleRate ?? 48000.0
                            let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
                            hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                        } }
                    )) {
                        Text("None").tag(nil as HRIRPreset?)
                        ForEach(hrirManager.presets) { preset in
                            Text(preset.name).tag(preset as HRIRPreset?)
                        }
                    }
                    .frame(width: 200)

                    Button("Open HRIR Folder") {
                        hrirManager.openPresetsDirectory()
                    }

                    // if hrirManager.activePreset != nil {
                    //     Button("Remove") {
                    //         if let preset = hrirManager.activePreset {
                    //             hrirManager.removePreset(preset)
                    //         }
                    //     }
                    //     .foregroundColor(.red)
                    // }
                }

                // Convolution Toggle
                HStack {
                    Text("Convolution:")
                        .frame(width: 120, alignment: .trailing)
                    Toggle("Enable HRIR Processing", isOn: $hrirManager.convolutionEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(hrirManager.activePreset == nil)

                    if hrirManager.activePreset == nil {
                        Text("(Select a preset first)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)

            Divider()

            // Control Buttons and Status
            HStack(spacing: 20) {
                Button(action: {
                    if audioManager.isRunning {
                        audioManager.stop()
                    } else {
                        audioManager.start()
                    }
                }) {
                    HStack {
                        Image(systemName: audioManager.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(audioManager.isRunning ? "Stop" : "Start")
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(audioManager.inputDevice == nil || audioManager.outputDevice == nil)

                // Status Indicator
                HStack {
                    Circle()
                        .fill(audioManager.isRunning ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    Text(audioManager.isRunning ? "Running" : "Stopped")
                        .font(.subheadline)
                }
            }
            .padding()

            // Error Message
            if let error = audioManager.errorMessage ?? hrirManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 600)
        .onAppear {
            if !isInitialized {
                // Connect HRIR manager to audio manager
                audioManager.hrirManager = hrirManager
                isInitialized = true
            }
            loadDevices()
            loadSettings()
        }
    }

    // MARK: - Helper Methods

    private func loadDevices() {
        inputDevices = AudioDeviceManager.getInputDevices()
        outputDevices = AudioDeviceManager.getOutputDevices()

        // Try to select BlackHole as default input if available
        if let blackHole = inputDevices.first(where: { $0.name.contains("BlackHole") }) {
            audioManager.selectInputDevice(blackHole)
        }

        // Select system default output
        if let defaultOutput = AudioDeviceManager.getDefaultOutputDevice() {
            audioManager.selectOutputDevice(defaultOutput)
        }
    }

    private func loadSettings() {
        let settings = settingsManager.loadSettings()

        // Restore input device
        if let deviceID = settings.selectedInputDeviceID,
           let device = inputDevices.first(where: { $0.id == deviceID }) {
            audioManager.selectInputDevice(device)
        }

        // Restore output device
        if let deviceID = settings.selectedOutputDeviceID,
           let device = outputDevices.first(where: { $0.id == deviceID }) {
            audioManager.selectOutputDevice(device)
        }

        // Restore active preset
        if let presetID = settings.activePresetID,
           let preset = hrirManager.presets.first(where: { $0.id == presetID }) {
            let inputLayout = InputLayout.detect(channelCount: 2) // Will be updated when audio starts
            hrirManager.activatePreset(preset, targetSampleRate: settings.targetSampleRate, inputLayout: inputLayout)
        }

        // Restore convolution state
        hrirManager.convolutionEnabled = settings.convolutionEnabled
    }

    private func saveSettings() {
        let settings = AppSettings(
            selectedInputDeviceID: audioManager.inputDevice?.id,
            selectedOutputDeviceID: audioManager.outputDevice?.id,
            activePresetID: hrirManager.activePreset?.id,
            convolutionEnabled: hrirManager.convolutionEnabled,
            bufferSize: 65536,
            targetSampleRate: audioManager.outputDevice?.sampleRate ?? 48000.0
        )
        settingsManager.saveSettings(settings)
    }
}

#Preview {
    ContentView()
}
