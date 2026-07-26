import SwiftUI

@main
struct AirwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MenuBarViewModel.shared
    @StateObject private var menuVisibility = MenuBarVisibilityManager.shared

    init() {
        do {
            try SettingsSchemaV2Migrator(
                defaults: .standard,
                launchAtLogin: LaunchAtLoginManager.shared
            ).migrateIfNeeded()
        } catch {
            Logger.log("[Migration] Could not enable launch at login: \(error)")
        }
        _ = UpdateManager.shared
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuVisibility.visibilityBinding) {
            AirwaveMenuView()
                .environmentObject(viewModel)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }

}
