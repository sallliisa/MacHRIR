import SwiftUI

struct SettingsView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginManager.shared
    @State private var isCheckingPermissions = false
    @State private var permissionStatus: PermissionStatus = .unknown
    @State private var showPermissionAlert = false
    
    enum PermissionStatus {
        case unknown
        case granted
        case denied
        case notDetermined
        
        var displayText: String {
            switch self {
            case .unknown: return "Unknown"
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not Requested"
            }
        }
        
        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .granted: return Color(red: 0.0, green: 0.6, blue: 0.0)
            case .denied: return .red
            case .notDetermined: return .orange
            }
        }
        
        var icon: String {
            switch self {
            case .unknown: return "questionmark.circle.fill"
            case .granted: return "checkmark.circle.fill"
            case .denied: return "xmark.circle.fill"
            case .notDetermined: return "exclamationmark.circle.fill"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.blue.gradient)
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // General Section
                    SettingsSection(
                        icon: "power.circle.fill",
                        iconColor: .green,
                        title: "General"
                    ) {
                        SettingsRow(
                            icon: "play.circle.fill",
                            iconColor: .blue,
                            title: "Launch at Login",
                            subtitle: "Start MacHRIR automatically when you log in"
                        ) {
                            Toggle("", isOn: $launchAtLogin.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    
                    // Permissions Section
                    SettingsSection(
                        icon: "lock.shield.fill",
                        iconColor: .orange,
                        title: "Permissions"
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text("Microphone Access")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        
                                        // Status Badge
                                        HStack(spacing: 4) {
                                            Image(systemName: permissionStatus.icon)
                                                .font(.system(size: 9))
                                            Text(permissionStatus.displayText)
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule()
                                                .fill(permissionStatus.color.gradient)
                                        )
                                    }
                                    
                                    Text("Required to capture audio from the aggregate device for HRIR processing.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                Spacer()
                            }
                            
                            Button(action: {
                                handlePermissionCheck()
                            }) {
                                HStack(spacing: 6) {
                                    if isCheckingPermissions {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: permissionStatus == .granted ? "checkmark.shield.fill" : "arrow.clockwise")
                                            .font(.system(size: 12))
                                    }
                                    Text(buttonText)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isCheckingPermissions)
                        }
                        .padding(12)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 480, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            checkCurrentPermissionStatus()
        }
        .alert("Microphone Access Granted", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("MacHRIR already has microphone access. You're all set!")
        }
    }
    
    private var buttonText: String {
        if isCheckingPermissions {
            return "Checking..."
        }
        
        switch permissionStatus {
        case .granted:
            return "Recheck Status"
        case .denied:
            return "Open System Settings"
        case .notDetermined:
            return "Request Permission"
        case .unknown:
            return "Check Permissions"
        }
    }
    
    private func checkCurrentPermissionStatus() {
        permissionStatus = PermissionManager.shared.getCurrentPermissionStatus()
    }
    
    private func handlePermissionCheck() {
        isCheckingPermissions = true
        
        PermissionManager.shared.checkAndRequestMicrophonePermission { granted in
            isCheckingPermissions = false
            checkCurrentPermissionStatus()
            
            if granted {
                showPermissionAlert = true
            } else if permissionStatus == .denied {
                PermissionManager.shared.openSystemSettings()
            }
        }
    }
}

// MARK: - Supporting Views

struct SettingsSection<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let content: Content
    
    init(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor.gradient)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .padding(.leading, 4)
            
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let content: Content
    
    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor.gradient)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            content
        }
        .padding(12)
    }
}
