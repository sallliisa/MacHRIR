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
                    onboardingNavigationDirection = step.index > onboarding.currentStep.index
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

}
