//
//  SettingsManager.swift
//  Airwave
//
//  UserDefaults-based settings persistence (sandbox-compatible)
//

import Foundation
import CoreAudio

/// Application settings
struct AppSettings: Codable {
    // DEPRECATED: Keep for backward compatibility
    var aggregateDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32?

    // NEW: Persistent identifiers
    var aggregateDeviceUID: String?
    var selectedOutputDeviceUID: String?

    var activePresetID: UUID?
    var autoStart: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            aggregateDeviceID: nil,
            selectedOutputDeviceID: nil,
            aggregateDeviceUID: nil,
            selectedOutputDeviceUID: nil,
            activePresetID: nil,
            autoStart: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
    }
}

/// Manages application settings persistence using UserDefaults
/// **IMPORTANT**: Always use `SettingsManager.shared` to avoid cache divergence.
/// Each instance maintains its own cache and debounce timer, which can lead to
/// stale reads or lost saves if multiple instances are used.
class SettingsManager {
    
    // Singleton instance - use this to ensure settings consistency
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let settingsKey = "Airwave.AppSettings"
    
    private var cachedSettings: AppSettings?
    private var saveWorkItem: DispatchWorkItem?

    init() {
        Logger.log("[Settings] Initialized with UserDefaults")
    }

    /// Load settings from memory cache or UserDefaults
    func loadSettings() -> AppSettings {
        if let settings = cachedSettings {
            return settings
        }
        let settings = loadSettingsFromDisk()
        cachedSettings = settings
        return settings
    }

    /// Load settings from UserDefaults (internal)
    private func loadSettingsFromDisk() -> AppSettings {
        Logger.log("[Settings] Loading settings from UserDefaults")
        
        guard let data = defaults.data(forKey: settingsKey) else {
            Logger.log("[Settings] No settings found in UserDefaults, using defaults")
            return .default
        }
        
        // Try to decode current schema
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            Logger.log("[Settings] Loaded settings from disk")
            return settings
        }
        
        // Migration: Attempt to migrate from legacy schema versions
        Logger.log("[Settings] Failed to decode with current schema, attempting migration...")
        
        if let migratedSettings = attemptMigration(from: data) {
            Logger.log("[Settings] Successfully migrated settings from legacy schema")
            // Save migrated settings in new format
            saveSettings(migratedSettings)
            return migratedSettings
        }
        
        // Last resort: Data is corrupted or truly incompatible
        Logger.log("[Settings] ⚠️ Migration failed. Data may be corrupted. Resetting to defaults.")
        return .default
    }
    
    /// Attempt to migrate settings from known legacy schema versions
    private func attemptMigration(from data: Data) -> AppSettings? {
        // Define legacy schema for migration
        struct LegacyAppSettings: Codable {
            var aggregateDeviceID: UInt32?
            var selectedOutputDeviceID: UInt32?
            var activePresetID: UUID?
            var autoStart: Bool
            var bufferSize: Int
            var targetSampleRate: Double
        }
        
        // Try to decode legacy schema (without UID fields)
        if let legacy = try? JSONDecoder().decode(LegacyAppSettings.self, from: data) {
            Logger.log("[Settings] Detected legacy schema (device IDs only)")
            // Convert to new schema - UIDs will be nil, user will need to reselect
            return AppSettings(
                aggregateDeviceID: legacy.aggregateDeviceID,
                selectedOutputDeviceID: legacy.selectedOutputDeviceID,
                aggregateDeviceUID: nil,
                selectedOutputDeviceUID: nil,
                activePresetID: legacy.activePresetID,
                autoStart: legacy.autoStart,
                bufferSize: legacy.bufferSize,
                targetSampleRate: legacy.targetSampleRate
            )
        }
        
        // Add more migration paths here as schema evolves
        
        return nil
    }

    /// Save settings to memory cache and schedule disk write
    func saveSettings(_ settings: AppSettings) {
        cachedSettings = settings
        debounceSave()
    }
    
    private func debounceSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Write cached settings to UserDefaults
    private func flush() {
        guard let settings = cachedSettings else { return }

        Logger.log("[Settings] Saving settings to UserDefaults:")
        Logger.log("  - Aggregate Device UID: \(settings.aggregateDeviceUID ?? "nil")")
        Logger.log("  - Output Device UID: \(settings.selectedOutputDeviceUID ?? "nil")")
        Logger.log("  - Active Preset ID: \(settings.activePresetID?.uuidString ?? "nil")")
        Logger.log("  - Auto Start: \(settings.autoStart)")

        guard let data = try? JSONEncoder().encode(settings) else {
            Logger.log("[Settings] Failed to encode settings")
            return
        }

        defaults.set(data, forKey: settingsKey)
    }
    
    // MARK: - Helper Methods
    
    func setAggregateDevice(_ device: AudioDevice) {
        guard let uid = device.uid else {
            Logger.log("[Settings] ⚠️ Could not get UID for device \(device.name)")
            return
        }
        var settings = loadSettings()
        settings.aggregateDeviceUID = uid
        saveSettings(settings)
    }

    func getAggregateDevice() -> AudioDevice? {
        guard let uid = loadSettings().aggregateDeviceUID else { return nil }
        return AudioDeviceManager.getDeviceByUID(uid)
    }

    func setOutputDevice(_ device: AudioDevice) {
        guard let uid = device.uid else {
            Logger.log("[Settings] ⚠️ Could not get UID for device \(device.name)")
            return
        }
        var settings = loadSettings()
        settings.selectedOutputDeviceUID = uid
        saveSettings(settings)
    }

    func getOutputDevice() -> AudioDevice? {
        guard let uid = loadSettings().selectedOutputDeviceUID else { return nil }
        return AudioDeviceManager.getDeviceByUID(uid)
    }
}
