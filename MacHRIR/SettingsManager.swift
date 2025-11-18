//
//  SettingsManager.swift
//  MacHRIR
//
//  JSON-based settings persistence
//

import Foundation
import CoreAudio

/// Application settings
struct AppSettings: Codable {
    var selectedInputDeviceID: UInt32?
    var selectedOutputDeviceID: UInt32?
    var activePresetID: UUID?
    var convolutionEnabled: Bool
    var bufferSize: Int
    var targetSampleRate: Double

    static var `default`: AppSettings {
        return AppSettings(
            selectedInputDeviceID: nil,
            selectedOutputDeviceID: nil,
            activePresetID: nil,
            convolutionEnabled: false,
            bufferSize: 65536,
            targetSampleRate: 48000.0
        )
    }
}

/// Manages application settings persistence
class SettingsManager {

    private let settingsURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("MacHRIR", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        settingsURL = appDirectory.appendingPathComponent("settings.json")
    }

    /// Load settings from disk
    func loadSettings() -> AppSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }

        return settings
    }

    /// Save settings to disk
    func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            print("Failed to encode settings")
            return
        }

        try? data.write(to: settingsURL)
    }
}
