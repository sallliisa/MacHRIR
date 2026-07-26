import SwiftUI

#if DEBUG
/// Runtime health inspector for Debug builds. It observes `AudioRuntimeState`
/// privately so runtime ticks never re-render the whole settings page.
struct SettingsDebugHealthSection: View {
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @EnvironmentObject private var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Debug Health",
                subtitle: "Inspect the native process-tap runtime."
            )

            VStack(spacing: 0) {
                debugRow("Status", value: runtime.status.title)
                Divider().padding(.leading, 30)
                debugRow("Detail", value: runtime.status.detail)
                Divider().padding(.leading, 30)
                debugRow("Current Output", value: runtime.currentOutput?.name ?? "Not available")
                Divider().padding(.leading, 30)
                debugRow("Sample Rate", value: sampleRate)
                Divider().padding(.leading, 30)
                debugRow("Process Tap", value: runtime.status.isProcessing ? "Active" : "Inactive")

                if RuntimeMenuPresentation.make(from: runtime.status).canRetry {
                    Divider().padding(.leading, 30)
                    AirwaveSettingsRow(
                        icon: "arrow.clockwise",
                        title: "Retry Audio Setup",
                        subtitle: "Ask the runtime to retry immediately"
                    ) {
                        actionButton("Retry", action: viewModel.retryAudio)
                    }
                }
                if runtime.status == .needsPermission {
                    Divider().padding(.leading, 30)
                    AirwaveSettingsRow(
                        icon: "lock.open.fill",
                        title: "System Audio Capture",
                        subtitle: "Open the macOS privacy setting for Airwave"
                    ) {
                        actionButton("Open Settings", action: viewModel.openSystemAudioRecordingSettings)
                    }
                }
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private var sampleRate: String {
        guard let rate = runtime.currentOutput?.nominalSampleRate else { return "—" }
        return "\(Int(rate.rounded())) Hz"
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .frame(width: 180, alignment: .trailing)
    }

    private func debugRow(_ title: String, value: String) -> some View {
        AirwaveSettingsRow(icon: "ladybug.fill", title: title) {
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 360, alignment: .trailing)
        }
    }
}
#endif
