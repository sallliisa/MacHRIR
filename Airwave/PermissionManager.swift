import AVFoundation
import AppKit

class PermissionManager {
    static let shared = PermissionManager()
    
    /// Notification posted when microphone permission status changes
    static let microphonePermissionDidChangeNotification = Notification.Name("MicrophonePermissionDidChange")
    
    // Checks permission and requests if necessary.
    // Returns true if authorized, false otherwise.
    // Always posts a notification with current status to keep UI in sync.
    func checkAndRequestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Post notification even when already authorized
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: PermissionManager.microphonePermissionDidChangeNotification,
                    object: nil,
                    userInfo: ["granted": true]
                )
                completion(true)
            }
            
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
            // Post notification even when denied/restricted
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: PermissionManager.microphonePermissionDidChangeNotification,
                    object: nil,
                    userInfo: ["granted": false]
                )
                completion(false)
            }
            
        @unknown default:
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: PermissionManager.microphonePermissionDidChangeNotification,
                    object: nil,
                    userInfo: ["granted": false]
                )
                completion(false)
            }
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
