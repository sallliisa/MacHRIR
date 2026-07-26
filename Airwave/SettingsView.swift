import AppKit
import SwiftUI

struct SettingsView: View {
    var showSetup: () -> Void
    var page: Binding<SettingsPage>
    @ObservedObject private var onboarding = OnboardingViewModel.shared
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
                                SettingsDebugHealthSection()
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
        .frame(
            width: SettingsWindowPresenter.contentSize.width,
            height: SettingsWindowPresenter.contentSize.height
        )
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
                AirwaveSettingsRow(
                    icon: "play.circle.fill",
                    title: "Launch at Login",
                    subtitle: "Open Airwave automatically when you log in"
                ) {
                    Toggle("", isOn: $launchAtLogin.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider().padding(.leading, 30)

                AirwaveSettingsRow(
                    icon: "menubar.rectangle",
                    title: "Show in Menu Bar",
                    subtitle: "Keep Airwave available from the macOS menu bar."
                ) {
                    Toggle("", isOn: menuVisibility.visibilityBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider().padding(.leading, 30)

                AirwaveSettingsRow(
                    icon: updateIconName,
                    title: "Software Update",
                    subtitle: updateStatusText,
                    iconColor: updateIconColor,
                    subtitleLineLimit: 2
                ) {
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

    private func settingsActionRow(
        icon: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        showsWarning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        AirwaveSettingsRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            showsWarning: showsWarning
        ) {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .frame(width: 180, alignment: .trailing)
        }
    }

    private var onboardingNeedsAttention: Bool {
        onboarding.needsSetupAttention
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
