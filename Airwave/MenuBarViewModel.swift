import AppKit
import Combine

/// Actions facade for the menu bar and the settings pages: it owns no state of
/// its own (hence no `@Published`), it is the one path through which the UI
/// mutates preset selection and drives runtime actions.
@MainActor
final class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel()

    let runtime: AudioRuntimeState
    let hrirManager: HRIRManager
    let profileManager: DeviceProfileManager
    let updateManager: UpdateManager
    private let runtimeActions: AudioRuntimeUserActions

    init(
        runtime: AudioRuntimeState,
        hrirManager: HRIRManager,
        profileManager: DeviceProfileManager,
        updateManager: UpdateManager,
        runtimeActions: AudioRuntimeUserActions
    ) {
        self.runtime = runtime
        self.hrirManager = hrirManager
        self.profileManager = profileManager
        self.updateManager = updateManager
        self.runtimeActions = runtimeActions
    }

    @MainActor
    convenience init() {
        self.init(
            runtime: .shared,
            hrirManager: .shared,
            profileManager: .shared,
            updateManager: .shared,
            runtimeActions: AudioRuntimeController.shared
        )
    }

    /// Selection for the device Airwave is currently playing through.
    func selectPreset(_ preset: HRIRPreset?) {
        profileManager.setCurrentHRIRPresetID(preset?.id)
    }

    /// Selection for the device being edited in Settings, which is not
    /// necessarily the current output.
    func selectEditingHRIRPreset(_ preset: HRIRPreset?) {
        profileManager.setHRIRPresetID(preset?.id)
    }

    func selectEditingEqualizerPreset(_ presetID: UUID?) {
        profileManager.setEqualizerPresetID(presetID)
    }

    var currentHRIRPreset: HRIRPreset? {
        hrirManager.presets.first { $0.id == profileManager.currentProfile?.hrirPresetID }
    }

    static func sortedPresets(_ presets: [HRIRPreset]) -> [HRIRPreset] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func openPresetsDirectory() {
        hrirManager.openPresetsDirectory()
    }

    var presentation: RuntimeMenuPresentation {
        .make(from: runtime.status)
    }

    func retryAudio() {
        runtimeActions.retryNow()
    }

    func openSystemAudioRecordingSettings() {
        runtimeActions.openSystemAudioRecordingSettings()
    }

    func openSupport() {
        guard let url = URL(string: "https://github.com/sallliisa/Airwave/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        closeMenuBarPopover()
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
        NSApp.orderFrontStandardAboutPanel(nil)
        if let window = NSApp.windows.first(where: { $0.title.localizedCaseInsensitiveContains("About") }) {
            window.identifier = ApplicationLifecycleCoordinator.aboutWindowIdentifier
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeMenuBarPopover() {
        NSApp.windows.first(where: ApplicationLifecycleCoordinator.isMenuBarPopover)?.close()
    }

    func quitApp() {
        ApplicationLifecycleCoordinator.shared.requestExplicitQuit()
    }
}
