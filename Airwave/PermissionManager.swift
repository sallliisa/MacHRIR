import AVFoundation
import AppKit

class PermissionManager {
    static let shared = PermissionManager()
    
    /// Notification posted when microphone permission status changes
    static let microphonePermissionDidChangeNotification = Notification.Name("MicrophonePermissionDidChange")
    
    // Checks permission and requests if necessary.
    // Returns true if authorized, false otherwise.
    // Also posts a notification when permission status changes.
    func checkAndRequestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    // Post notification when permission is determined
                    NotificationCenter.default.post(
                        name: PermissionManager.microphonePermissionDidChangeNotification,
                        object: nil,
                        userInfo: ["granted": granted]
                    )
                    completion(granted)
                }
            }
            
        case .denied, .restricted:
            completion(false)
            
        @unknown default:
            completion(false)
        }
    }
    
    /// Request microphone permission and post notification when determined.
    /// Use this method on app launch to trigger the permission prompt.
    func requestMicrophonePermissionIfNeeded() {
        if currentMicrophoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    // Post notification when permission is determined
                    NotificationCenter.default.post(
                        name: PermissionManager.microphonePermissionDidChangeNotification,
                        object: nil,
                        userInfo: ["granted": granted]
                    )
                }
            }
        }
    }
    
    // Get the raw authorization status
    var currentMicrophoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
