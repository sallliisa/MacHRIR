import SwiftUI

enum OnboardingNavigationDirection {
    case forward
    case backward
}

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Binding var navigationDirection: OnboardingNavigationDirection
    var canReturnToSettings = false
    var onComplete: () -> Void = {}
    var onReturnToSettings: () -> Void = {}
    var onOpenEqualizerSettings: () -> Void = {}
    @ObservedObject private var runtime = AudioRuntimeState.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var menuVisibility = MenuBarVisibilityManager.shared
    @EnvironmentObject private var menuViewModel: MenuBarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            AirwavePalette.canvas.ignoresSafeArea()
            content
            AirwaveScrollEdgeFades()
        }
        .overlay(alignment: .bottom) {
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(
            width: SettingsWindowPresenter.contentSize.width,
            height: SettingsWindowPresenter.contentSize.height
        )
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        AirwavePageLayout(mode: .compact) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: AirwaveLayout.pageHeaderContentMinimumSpacing) {
                    stepHeader
                    stepBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(viewModel.currentStep)
                .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var currentPageNumber: Int { viewModel.currentStep.pageNumber }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .airwaveBlurScaleReveal
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : AirwaveMotion.pageTransition
    }

    private func navigate(to step: OnboardingStepV2) {
        guard step != viewModel.currentStep else { return }
        navigationDirection = step.index > viewModel.currentStep.index ? .forward : .backward
        withAnimation(pageAnimation) { viewModel.selectStep(step) }
    }

    private func navigateForward() {
        navigationDirection = .forward
        withAnimation(pageAnimation) { viewModel.advance() }
    }

    private func navigateBackward() {
        navigationDirection = .backward
        withAnimation(pageAnimation) { viewModel.goBack() }
    }


    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(currentStepTitle).font(.largeTitle.weight(.semibold))
            Text(stepProgressLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var currentStepTitle: String {
        if viewModel.currentStep == .liveHealth, runtime.hasBlockingHealthIssue { return "Airwave needs attention" }
        if viewModel.currentStep == .liveHealth { return readinessPresentation.title }
        return viewModel.currentStep.title
    }

    private var stepProgressLabel: String {
        switch viewModel.currentStep {
        case .welcome: "Before you begin"
        case .liveHealth:
            runtime.hasBlockingHealthIssue
                ? "Health & Troubleshooting"
                : (isRuntimeReady ? "All is set. Airwave is now set up." : "Finish setup to use Airwave.")
        default: "Step \(currentPageNumber - 1) of 2"
        }
    }

    private var canComplete: Bool {
        viewModel.canComplete(allowingUnknownCapture: canReturnToSettings)
    }

    private var isRuntimeReady: Bool {
        runtime.isSetupHealthy
    }

    @ViewBuilder
    private var stepBody: some View {
        switch viewModel.currentStep {
        case .welcome: welcomeStep
        case .systemAudio: systemAudioStep
        case .hrirPreset: hrirStep
        case .liveHealth:
            ScrollView {
                liveHealthStep
                    .padding(.bottom, 88)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Set up Airwave for spatial audio.").font(.title3)
            Text("Airwave processes sound from your Mac and creates a spacious listening experience. Setup only takes a moment.")
                .foregroundStyle(.secondary)

            VStack(spacing: AirwaveLayout.cardSpacing) {
                infoCard(
                    "Allow system audio capture",
                    systemImage: "waveform.badge.mic",
                    text: "Airwave requires permission to capture system audio so it can apply spatial processing to sound from your Mac."
                )
                infoCard(
                    "Use stereo headphones",
                    systemImage: "headphones",
                    text: "HRIR works best with stereo headphones. Speakers and other outputs may not produce the intended spatial effect."
                )
            }
        }
    }

    private var systemAudioStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Allow Airwave to capture system audio so it can apply the selected HRIR preset. Airwave does not use microphone access.")
            captureAccessCard
            if let guidance = viewModel.captureFailureGuidance {
                captureFailureGuidance(guidance)
            }
            captureTestControls
        }
    }

    @ViewBuilder
    private var captureTestControls: some View {
        HStack {
            switch viewModel.captureAccessPresentation {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Playing a short test sound…").font(.callout).foregroundStyle(.secondary)
            case .unverified:
                if viewModel.captureFailureGuidance == nil {
                    Button("Test System Audio Capture") { viewModel.requestPermission() }
                        .buttonStyle(.borderedProminent)
                }
            case .verified:
                Button("Test Again") { viewModel.requestPermission() }
                    .buttonStyle(.borderedProminent)
            case .permissionRequired, .failed:
                EmptyView()
            }
        }
    }

    private func captureFailureGuidance(_ guidance: CaptureFailureGuidance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try these fixes")
                .font(.system(size: 13, weight: .medium))

            if let reason = guidance.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(guidance.suggestions, id: \.self) { suggestion in
                    suggestionRow(suggestion)
                }
            }

            HStack(spacing: 14) {
                Button("Open System Settings") { viewModel.openPermissionSettings() }
                    .buttonStyle(.link)
                Button("Test Again") { viewModel.requestPermission() }
                    .buttonStyle(.link)
            }
        }
        .padding(AirwaveLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture troubleshooting suggestions")
    }

    private var hrirStep: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            Text("Choose the HRIR preset used by Airwave for processing. You can play audio in the background to audition it in real time")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            AirwaveHRIRPicker(
                manager: hrirManager,
                selectedID: profiles.currentProfile?.hrirPresetID,
                onSelect: menuViewModel.selectPreset,
                onDelete: { preset in
                    if profiles.currentProfile?.hrirPresetID == preset.id {
                        menuViewModel.selectPreset(nil)
                    }
                }
            )
            .frame(height: 260, alignment: .top)
            .disabled(profiles.currentDeviceUID == nil)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
    }

    private var liveHealthStep: some View {
        let presentation = readinessPresentation
        return VStack(alignment: .leading, spacing: AirwaveLayout.sectionSpacing) {
            if runtime.healthIssues.isEmpty {
                statusCard(
                    icon: isRuntimeReady
                        ? "checkmark.seal.fill"
                        : (presentation.isAttention ? "exclamationmark.triangle.fill" : "info.circle.fill"),
                    color: isRuntimeReady ? .green : (presentation.isAttention ? .orange : .secondary),
                    title: presentation.title,
                    detail: presentation.detail
                )

                if let actionStep = presentation.actionStep {
                    Button(presentation.actionTitle ?? (actionStep == .systemAudio ? "Review Capture" : "Choose a Preset")) {
                        navigate(to: actionStep)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if presentation.canRetry {
                    Button("Retry") { viewModel.retry() }.buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(Array(runtime.healthIssues.enumerated()), id: \.offset) { _, issue in
                    healthIssueCard(RuntimeHealthIssuePresentation.make(for: issue))
                }
            }

            VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
                AirwaveSectionHeader(
                    title: "Application",
                    subtitle: "Choose whether Airwave starts automatically."
                )

                VStack(spacing: 0) {
                    applicationToggleRow(icon: "play.circle.fill", title: "Launch at Login", subtitle: "Start Airwave automatically when you log in", isOn: $launchAtLogin.isEnabled)
                    Divider().padding(.leading, 42)
                    applicationToggleRow(icon: "menubar.rectangle", title: "Show in Menu Bar", subtitle: "Keep Airwave available from the macOS menu bar.", isOn: menuVisibility.visibilityBinding)
                }
                .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
            }
        }
    }

    private func healthIssueCard(_ presentation: RuntimeHealthIssuePresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
            Text(presentation.detail).font(.callout).foregroundStyle(.secondary)
            ForEach(presentation.suggestions, id: \.self) { suggestion in
                suggestionRow(suggestion)
            }
            Button(presentation.actionTitle) { perform(presentation.action) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(AirwaveLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
    }

    private func suggestionRow(_ suggestion: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•")
            Text(suggestion)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func perform(_ action: RuntimeHealthRecoveryAction) {
        switch action {
        case .reviewCapture: navigate(to: .systemAudio)
        case .retry: viewModel.retry()
        case .chooseHRIR: navigate(to: .hrirPreset)
        case .openEqualizer: onOpenEqualizerSettings()
        }
    }

    private func applicationToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        AirwaveSettingsRow(icon: icon, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }


    private var footer: some View {
        let isCompletion = viewModel.currentStep == .liveHealth
        let primaryLabel = isCompletion
            ? (profiles.currentProfile?.hrirPresetID == nil ? "Finish Setup" : "Start Airwave")
            : (viewModel.currentStep == .welcome ? "Begin Setup" : "Continue")

        return HStack {
            if canReturnToSettings {
                Button(action: onReturnToSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back to Settings")
                    }
                }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            AirwaveIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Back",
                help: "Back",
                isProminent: false,
                isEnabled: viewModel.currentStep != .welcome,
                action: navigateBackward
            )

            AirwaveIconButton(
                systemImage: isCompletion ? "play.fill" : "arrow.right",
                accessibilityLabel: primaryLabel,
                help: primaryLabel,
                isProminent: true,
                isEnabled: isCompletion ? canComplete : true
            ) {
                if isCompletion {
                    if viewModel.complete(allowingUnknownCapture: canReturnToSettings) { onComplete() }
                } else {
                    navigateForward()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var captureAccessCard: some View {
        let icon: String
        let color: Color
        let detail: String
        switch viewModel.captureAccessPresentation {
        case .unverified:
            icon = "circle"
            color = .secondary
            detail = "Airwave will play a short sound and listen for captured system audio."
        case .checking:
            icon = "hourglass"
            color = .secondary
            detail = "A short test sound may play while Airwave verifies captured PCM."
        case .verified:
            icon = "checkmark.seal.fill"
            color = .green
            detail = "Airwave successfully captured system audio."
        case .permissionRequired:
            icon = "exclamationmark.triangle.fill"
            color = .orange
            detail = "Enable Airwave in Privacy & Security, then test again."
        case .failed(let reason):
            icon = "exclamationmark.triangle.fill"
            color = .orange
            detail = reason
        }
        return statusCard(icon: icon, color: color, title: "System Audio Capture", detail: detail)
    }

    private var readinessPresentation: OnboardingReadinessPresentation {
        OnboardingReadinessPresentation.make(
            captureAccess: viewModel.captureAccessPresentation,
            hasPreset: profiles.currentProfile?.hrirPresetID != nil,
            runtimeStatus: runtime.status,
            isReady: isRuntimeReady,
            hasCaptureFailureGuidance: viewModel.captureFailureGuidance != nil
        )
    }

    private func statusCard(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AirwaveLayout.cardPadding)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
    }

    private func infoCard(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.primary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AirwaveLayout.cardPadding)
        .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
    }

}

struct OnboardingProgressIndicator: View {
    let currentStep: OnboardingStepV2
    let permission: CaptureAccessPresentation
    let hasCaptureFailureGuidance: Bool
    let hasPreset: Bool
    let isReady: Bool
    let onSelect: (OnboardingStepV2) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStepV2.allCases, id: \.self) { step in
                OnboardingProgressItem(
                    step: step,
                    status: status(for: step),
                    isCurrent: currentStep == step,
                    action: { onSelect(step) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }

    private func status(for step: OnboardingStepV2) -> ProgressStatus {
        switch step {
        case .welcome: return .complete
        case .systemAudio:
            if hasCaptureFailureGuidance { return .attention }
            switch permission {
            case .verified: return .complete
            case .permissionRequired, .failed: return .attention
            case .checking, .unverified: return .unknown
            }
        case .hrirPreset: return .complete
        case .liveHealth: return isReady ? .complete : .incomplete
        }
    }
}

private enum ProgressStatus {
    case checking
    case unknown
    case incomplete
    case attention
    case complete
}

private struct OnboardingProgressItem: View {
    let step: OnboardingStepV2
    let status: ProgressStatus
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: step.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background { Circle().fill(indicatorBackground) }
                .contentShape(Circle())
        }
        .buttonStyle(AirwavePressedButtonStyle())
        .help("\(step.title) — \(statusDescription)")
        .accessibilityLabel(step.title)
        .accessibilityValue(isCurrent ? "Current page, \(statusDescription)" : statusDescription)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }

    private var iconColor: Color {
        if isCurrent { return AirwavePalette.canvas }
        switch status {
        case .complete: return Color.white
        case .attention: return Color.orange
        case .checking, .unknown: return Color.primary
        case .incomplete: return Color.secondary
        }
    }

    private var indicatorBackground: Color {
        if isCurrent { return Color.primary.opacity(isHovering ? 0.78 : 0.92) }
        return isHovering ? AirwavePalette.hover : .clear
    }

    private var statusDescription: String {
        switch status {
        case .checking: "Checking"
        case .unknown: "Not checked"
        case .incomplete: "Needs setup"
        case .attention: "Action needed"
        case .complete: "Complete"
        }
    }
}
