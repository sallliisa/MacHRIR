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
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }
}
