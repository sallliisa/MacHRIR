import AppKit
import SwiftUI

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            SettingsWindowPresenter.register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            SettingsWindowPresenter.register(window)
        }
    }
}

struct SettingsWindowContent: View {
    @ObservedObject var state: SettingsWindowContentState
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onboardingNavigationDirection: OnboardingNavigationDirection = .forward
    @State private var isQuitConfirmationPresented = false

    private var modeTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : AirwaveMotion.pageTransition
    }

    var body: some View {
        ZStack {
            pageContent

            VStack(spacing: 0) {
                AirwaveTopBar {
                    topBarCenter
                } trailing: {
                    topBarTrailing
                }
                .animation(
                    reduceMotion ? nil : AirwaveMotion.pageTransition,
                    value: state.settingsPage
                )
                Spacer(minLength: 0)
            }
        }
        .frame(width: SettingsWindowPresenter.contentSize.width, height: SettingsWindowPresenter.contentSize.height)
        .animation(modeTransition, value: state.mode)
        .animation(modeTransition, value: state.canReturnToSettings)
        .background(SettingsWindowAccessor())
        .clipped()
        .confirmationDialog(
            "Quit Airwave?",
            isPresented: $isQuitConfirmationPresented
        ) {
            Button("Quit Airwave", role: .destructive) {
                ApplicationLifecycleCoordinator.shared.requestExplicitQuit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio processing will stop and Airwave will quit.")
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.mode {
        case .setup:
            OnboardingView(
                viewModel: OnboardingViewModel.shared,
                navigationDirection: $onboardingNavigationDirection,
                canReturnToSettings: state.canReturnToSettings,
                onComplete: { state.show(.settings) },
                onReturnToSettings: { state.show(.settings) },
                onOpenEqualizerSettings: {
                    state.show(.settings)
                    state.selectSettingsPage(.equalizer)
                }
            )
            .transition(pageRevealTransition)
        case .settings:
            SettingsView(showSetup: {
                OnboardingViewModel.shared.prepareForPresentation(.voluntary)
                state.show(.setup, canReturnToSettings: true)
            }, page: Binding(
                get: { state.settingsPage },
                set: { state.selectSettingsPage($0) }
            ))
            .transition(pageRevealTransition)
        }
    }

    private var pageRevealTransition: AnyTransition {
        reduceMotion ? .opacity : .airwaveBlurScaleReveal
    }

    @ViewBuilder
    private var topBarCenter: some View {
        switch state.mode {
        case .setup:
            OnboardingProgressIndicator(
                currentStep: onboarding.currentStep,
                permission: onboarding.permissionPresentation,
                hasCaptureFailureGuidance: onboarding.captureFailureGuidance != nil,
                hasPreset: profiles.currentProfile?.hrirPresetID != nil,
                isReady: onboarding.runtime.isSetupHealthy,
                onSelect: { step in
                    onboardingNavigationDirection = onboardingIndex(of: step) > onboardingIndex(of: onboarding.currentStep)
                        ? .forward
                        : .backward
                    withAnimation(onboardingPageAnimation) {
                        onboarding.selectStep(step)
                    }
                }
            )
        case .settings:
            if state.settingsPage == .general || state.settingsPage == .equalizer {
                deviceMenu
            }
        }
    }

    private var deviceMenu: some View {
        Group {
            if let editing = profiles.editingTarget {
                Menu {
                    ForEach(profiles.targets) { target in
                        Button {
                            profiles.selectEditingDevice(uid: target.deviceUID)
                        } label: {
                            HStack {
                                if target.deviceUID == profiles.editingDeviceUID { Image(systemName: "checkmark") }
                                Text(target.deviceName)
                                if target.isCurrent { Text("Current") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(editing.deviceName)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Editing audio device")
                .accessibilityValue(editing.deviceName)
            } else {
                Text("No Supported Output").foregroundStyle(.secondary)
                    .accessibilityLabel("No supported output device")
            }
        }
    }

    @ViewBuilder
    private var topBarTrailing: some View {
        switch state.mode {
        case .setup:
            Text("Page \(onboardingPageNumber) of \(OnboardingStepV2.allCases.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .settings:
            Button {
                isQuitConfirmationPresented = true
            } label: {
                Image(systemName: "power")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red)
            .accessibilityLabel("Quit Airwave and stop processing")
            .help("Quit Airwave and stop audio processing")
        }
    }

    private var onboardingPageNumber: Int {
        (OnboardingStepV2.allCases.firstIndex(of: onboarding.currentStep) ?? 0) + 1
    }

    private var onboardingPageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : AirwaveMotion.pageTransition
    }

    private func onboardingIndex(of step: OnboardingStepV2) -> Int {
        OnboardingStepV2.allCases.firstIndex(of: step) ?? 0
    }
}

struct SettingsView: View {
    var showSetup: () -> Void
    var page: Binding<SettingsPage> = .constant(.general)
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var menuVisibility = MenuBarVisibilityManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AirwavePalette.canvas.ignoresSafeArea()

            AirwavePageLayout(mode: pageLayoutMode) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader

                        Color.clear.frame(height: AirwaveLayout.pageHeaderContentMinimumSpacing)

                        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
                            settingsPageContent
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            #if DEBUG
                            if page.wrappedValue == .general {
                                debugSection
                            }
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(page.wrappedValue)
                    .transition(pageRevealTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(settingsPageAnimation, value: page.wrappedValue)
            }

        }
        .frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
    }

    private var pageLayoutMode: AirwavePageLayoutMode {
        switch page.wrappedValue {
        case .general: .fullScreen
        case .equalizer: .compact
        case .devices, .application: .compact
        }
    }

    private var settingsPageAnimation: Animation? {
        reduceMotion ? nil : AirwaveMotion.pageTransition
    }

    private var pageRevealTransition: AnyTransition {
        reduceMotion ? .opacity : .airwaveBlurScaleReveal
    }

    @ViewBuilder
    private var settingsPageContent: some View {
        switch page.wrappedValue {
        case .general:
            generalPage
        case .equalizer:
            EqualizerSettingsView()
        case .devices:
            DeviceManagementView()
        case .application:
            applicationPage
        }
    }

    private var generalPage: some View {
        AirwaveEqualHeightColumnsLayout(spacing: AirwaveLayout.cardSpacing) {
            spatialProfileSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            applicationSection
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 14) {
                if page.wrappedValue != .general {
                    AirwaveIconButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "Back to Settings",
                        help: "Back to Settings",
                        isProminent: false,
                        isEnabled: true
                    ) {
                        page.wrappedValue = .general
                    }
                }
                Text(pageTitle).font(.largeTitle.weight(.semibold))
                if page.wrappedValue == .general, onboardingNeedsAttention {
                    Label(
                        onboarding.isComplete ? "Airwave needs attention" : "Complete setup",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            Text(pageSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var pageTitle: String {
        page.wrappedValue == .general ? "Settings" : page.wrappedValue.title
    }

    private var pageSubtitle: String {
        switch page.wrappedValue {
        case .general:
            "Choose your spatial profile and application preferences."
        case .equalizer:
            "Import and choose an EqualizerAPO-format preset."
        case .devices:
            "Review, reset, or forget registered devices."
        case .application:
            "Manage startup, updates, and app information."
        }
    }

    private var spatialProfileSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AirwaveSectionHeader(
                title: "Spatial Profile",
                subtitle: "Choose the HRIR preset Airwave uses for spatial audio."
            )
            .padding(AirwaveLayout.cardPadding)

            Divider()

            AirwaveHRIRPicker(
                manager: hrirManager,
                selectedID: profiles.editingProfile?.hrirPresetID,
                onSelect: { viewModel.selectEditingHRIRPreset($0) },
                onDelete: { preset in
                    if profiles.editingProfile?.hrirPresetID == preset.id {
                        viewModel.selectEditingHRIRPreset(nil)
                    }
                }
            )
            .frame(minHeight: 300, maxHeight: .infinity)
        }
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            AirwaveSectionHeader(
                title: "Application",
                subtitle: "Startup, updates, setup, and app information."
            )

            VStack(spacing: AirwaveLayout.cardSpacing) {
                AirwaveNavigationCard(
                    systemImage: "slider.horizontal.3",
                    title: "Equalizer",
                    subtitle: "Import and choose an EqualizerAPO-format preset."
                ) {
                    page.wrappedValue = .equalizer
                }

                AirwaveNavigationCard(
                    systemImage: "headphones",
                    title: "Registered Devices",
                    subtitle: "Review, reset, or forget registered devices."
                ) {
                    page.wrappedValue = .devices
                }

                AirwaveNavigationCard(
                    systemImage: "sparkles",
                    title: "Setup & Troubleshooting",
                    subtitle: onboarding.isComplete && onboardingNeedsAttention
                        ? "Review current Airwave health issues and recovery steps."
                        : "Revisit the Airwave setup wizard.",
                    showsWarning: onboardingNeedsAttention
                ) {
                    showSetup()
                }

                AirwaveNavigationCard(
                    systemImage: "gearshape",
                    title: "Application",
                    subtitle: "Manage startup, updates, and app information."
                ) {
                    page.wrappedValue = .application
                }
            }
        }
    }

    private var applicationPage: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Launch at Login").font(.system(size: 12))
                        Text("Open Airwave automatically when you log in")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                HStack(spacing: 10) {
                    Image(systemName: "menubar.rectangle").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show in Menu Bar").font(.system(size: 12))
                        Text("Keep Airwave in the macOS menu bar.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: menuBarVisibilityBinding).labelsHidden().toggleStyle(.switch)
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                HStack(spacing: 10) {
                    Image(systemName: updateIconName)
                        .font(.system(size: 13))
                        .foregroundStyle(updateIconColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Software Update").font(.system(size: 12))
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if case .checking = updateManager.state {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(updateButtonTitle) {
                            if case .available = updateManager.state {
                                updateManager.presentAvailableUpdate()
                            } else {
                                updateManager.checkForUpdates()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!updateManager.canCheckForUpdates)
                    }
                }
                .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.rowVerticalPadding)

                Divider().padding(.leading, 30)

                settingsActionRow(
                    icon: "info.circle.fill",
                    title: "About Airwave",
                    subtitle: "Version and app information",
                    buttonTitle: "About…",
                    action: viewModel.showAbout
                )
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    #if DEBUG
    private var debugSection: some View {
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
                    settingsActionRow(
                        icon: "arrow.clockwise",
                        title: "Retry Audio Setup",
                        subtitle: "Ask the runtime to retry immediately",
                        buttonTitle: "Retry",
                        action: viewModel.retryAudio
                    )
                }
                if runtime.status == .needsPermission {
                    Divider().padding(.leading, 30)
                    settingsActionRow(
                        icon: "lock.open.fill",
                        title: "System Audio Capture",
                        subtitle: "Open the macOS privacy setting for Airwave",
                        buttonTitle: "Open Settings",
                        action: viewModel.openSystemAudioRecordingSettings
                    )
                }
            }
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private func debugRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 360, alignment: .trailing)
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
    }
    #endif

    private func settingsActionRow(
        icon: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        showsWarning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(showsWarning ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
        .background(showsWarning ? Color.orange.opacity(0.10) : Color.clear)
    }

    private var onboardingNeedsAttention: Bool {
        onboarding.needsSetupAttention
    }

    private var sampleRate: String {
        guard let rate = runtime.currentOutput?.nominalSampleRate else { return "—" }
        return "\(Int(rate.rounded())) Hz"
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { menuVisibility.isVisible },
            set: { value in
                guard value != menuVisibility.isVisible else { return }
                DispatchQueue.main.async { menuVisibility.setVisible(value) }
            }
        )
    }

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle: "Airwave \(updateManager.installedVersion)"
        case .checking: "Checking for updates…"
        case .current: "Airwave \(updateManager.installedVersion) is up to date"
        case .available(let version): "Airwave \(version) is available"
        case .error(let message): "Update check failed: \(message)"
        }
    }

    private var updateButtonTitle: String {
        if case .available = updateManager.state { return "Update…" }
        return "Check for Updates…"
    }

    private var updateIconName: String {
        switch updateManager.state {
        case .available: "arrow.down.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var updateIconColor: Color {
        switch updateManager.state {
        case .available: .blue
        case .error: .orange
        default: .secondary
        }
    }
}
