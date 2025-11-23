//
//  SettingsManager.swift
//  MacHRIR
//
//  UserDefaults-based settings persistence (sandbox-compatible)
//

import Foundation
import CoreAudio

/// Application settings
struct AppSettings: Codable {
    var aggregateDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32? // NEW: ID of the physical output device within the aggregate
    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            aggregateDeviceID: nil,
            selectedOutputDeviceID: nil,
            activePresetID: nil,
            convolutionEnabled: false,
            autoStart: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
    }
}

/// Manages application settings persistence using UserDefaults
class SettingsManager {
    
    // Singleton instance for easy access
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let settingsKey = "MacHRIR.AppSettings"

    init() {
        print("[Settings] Initialized with UserDefaults")
    }

    /// Load settings from UserDefaults
    func loadSettings() -> AppSettings {
        print("[Settings] Loading settings from UserDefaults")
        
        guard let data = defaults.data(forKey: settingsKey) else {
            print("[Settings] No settings found in UserDefaults, using defaults")
            return .default
        }
        
        // Try to decode new schema
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            print("[Settings] Loaded settings:")
            print("  - Aggregate Device ID: \(settings.aggregateDeviceID?.description ?? "nil")")
            print("  - Output Device ID: \(settings.selectedOutputDeviceID?.description ?? "nil")")
            print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
            print("  - Convolution Enabled: \(settings.convolutionEnabled)")
            print("  - Auto Start: \(settings.autoStart)")
            return settings
        }
        
        // Migration: If we fail to decode, it might be the old schema.
        print("[Settings] Failed to decode settings (possible schema mismatch). Resetting to defaults.")
        return .default
    }

    /// Save settings to UserDefaults
    func saveSettings(_ settings: AppSettings) {
        print("[Settings] Saving settings to UserDefaults:")
        print("  - Aggregate Device ID: \(settings.aggregateDeviceID?.description ?? "nil")")
        print("  - Output Device ID: \(settings.selectedOutputDeviceID?.description ?? "nil")")
        print("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        print("  - Convolution Enabled: \(settings.convolutionEnabled)")
        print("  - Auto Start: \(settings.autoStart)")
        
        guard let data = try? JSONEncoder().encode(settings) else {
            print("[Settings] Failed to encode settings")
            return
        }

        defaults.set(data, forKey: settingsKey)
        
        // Force synchronization to ensure data is written immediately
        if defaults.synchronize() {
            print("[Settings] Successfully saved and synchronized to UserDefaults")
        } else {
            print("[Settings] Warning: synchronize() returned false")
        }
    }
    
    // MARK: - Helper Methods
    
    func setAggregateDevice(_ deviceID: AudioDeviceID) {
        var settings = loadSettings()
        settings.aggregateDeviceID = deviceID
        saveSettings(settings)
    }
    
    func getAggregateDevice() -> AudioDeviceID? {
        return loadSettings().aggregateDeviceID
    }
    
    func setOutputDevice(_ deviceID: AudioDeviceID) {
        var settings = loadSettings()
        settings.selectedOutputDeviceID = deviceID
        saveSettings(settings)
    }
    
    func getOutputDevice() -> AudioDeviceID? {
        return loadSettings().selectedOutputDeviceID
    }
}
