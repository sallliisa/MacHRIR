import ServiceManagement
import SwiftUI
import Combine

class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    
    @Published var isEnabled: Bool {
        didSet {
            updateLoginItem()
        }
    }
    
    private init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }
    
    private func updateLoginItem() {
        do {
            if isEnabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    Logger.log("[LaunchAtLogin] Successfully registered for launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    Logger.log("[LaunchAtLogin] Successfully unregistered from launch at login")
                }
            }
        } catch {
            Logger.log("[LaunchAtLogin] ⚠️ Failed to update login item: \(error)")
            
            // Sync isEnabled back to actual system status to keep UI consistent
            let actualStatus = SMAppService.mainApp.status == .enabled
            if isEnabled != actualStatus {
                Logger.log("[LaunchAtLogin] Syncing isEnabled (\(isEnabled)) to actual status (\(actualStatus))")
                isEnabled = actualStatus
            }
        }
    }
}
