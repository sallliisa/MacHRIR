import AppKit
import Combine
import SwiftUI

@MainActor
enum SettingsPage: String, CaseIterable {
    case general
    case equalizer
    case devices
    case application

    var title: String {
        switch self {
        case .general: "General"
        case .equalizer: "Equalizer"
        case .devices: "Registered Devices"
        case .application: "Application"
        }
    }
}

@MainActor
final class SettingsWindowContentState: ObservableObject {
    enum Mode: Equatable {
        case setup
        case settings
    }

    @Published private(set) var mode: Mode = .settings
    @Published private(set) var canReturnToSettings = false
    @Published private(set) var settingsPage: SettingsPage = .general

    func selectSettingsPage(_ page: SettingsPage) {
        settingsPage = page
    }

    /// Plain state change; the view layer owns the transition animation.
    func show(_ mode: Mode, canReturnToSettings: Bool = false) {
        self.mode = mode
        self.canReturnToSettings = mode == .setup && canReturnToSettings
        if mode == .settings {
            self.settingsPage = .general
        }
    }
}
