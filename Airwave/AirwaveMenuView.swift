import SwiftUI

struct MenuBarLabel: View {
    var body: some View {
        Image("AirwaveMark")
            .renderingMode(.template)
            .accessibilityLabel("Airwave")
    }
}

private struct MenuHeaderSection: View {
    var body: some View {
        HStack(spacing: 8) {
            AirwaveBrandHeader(markSize: 16, titleFont: .system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MenuHoverBackground: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.primary.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct MenuAccordion<Content: View>: View {
    let title: String
    let value: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.system(size: 12)).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if !isExpanded {
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AirwaveLayout.menuRowHorizontalPadding)
                .padding(.vertical, AirwaveLayout.menuRowVerticalPadding)
                .modifier(MenuHoverBackground())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) { content() }
                    .padding(.leading, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct MenuSelectionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AirwaveLayout.menuRowHorizontalPadding)
            .padding(.vertical, AirwaveLayout.menuRowVerticalPadding)
            .modifier(MenuHoverBackground())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuActionRow: View {
    let title: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    var showWarning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                }
                Text(title)
                Spacer()
                if showWarning { Text("⚠️") }
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AirwaveLayout.menuRowHorizontalPadding)
            .padding(.vertical, AirwaveLayout.menuRowVerticalPadding)
            .modifier(MenuHoverBackground())
        }
        .buttonStyle(.plain)
    }
}

struct AirwaveMenuView: View {
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @ObservedObject private var hrirManager = HRIRManager.shared
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @ObservedObject private var onboarding = OnboardingViewModel.shared
    @State private var isPresetExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            MenuHeaderSection()

            Divider().padding(.horizontal, AirwaveLayout.menuDividerInset)

            MenuAccordion(
                title: "HRIR Preset",
                value: selectedPreset?.name ?? "None",
                isExpanded: isPresetExpanded,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.2)) { isPresetExpanded.toggle() }
                }
            ) {
                MenuSelectionRow(name: "None", isSelected: selectedPreset == nil) {
                    viewModel.selectPreset(nil)
                }
                ForEach(MenuBarViewModel.sortedPresets(hrirManager.presets)) { preset in
                    MenuSelectionRow(name: preset.name, isSelected: preset.id == selectedPreset?.id) {
                        viewModel.selectPreset(preset)
                    }
                }
            }
            .padding(.vertical, AirwaveLayout.menuGroupPadding)

            Divider().padding(.horizontal, AirwaveLayout.menuDividerInset)

            VStack(spacing: 2) {
                if onboarding.shouldShowSetupMenuItem {
                    MenuActionRow(
                        title: onboarding.isComplete ? "Troubleshoot Airwave…" : "Complete Set Up…",
                        showWarning: true
                    ) {
                        viewModel.closeMenuBarPopover()
                        onboarding.prepareForPresentation(.voluntary)
                        SettingsWindowPresenter.present(.setup)
                    }
                }
                MenuActionRow(title: "Settings") {
                    viewModel.closeMenuBarPopover()
                    SettingsWindowPresenter.present(.settings)
                }
            }
            .padding(.vertical, AirwaveLayout.menuGroupPadding)

            Divider().padding(.horizontal, AirwaveLayout.menuDividerInset)

            MenuActionRow(title: "Quit Airwave") { viewModel.quitApp() }
                .padding(.vertical, AirwaveLayout.menuGroupPadding)
        }
        .frame(width: 280)
        .padding(.horizontal, AirwaveLayout.menuOuterPadding)
        .padding(.vertical, AirwaveLayout.menuGroupPadding)
    }

    private var selectedPreset: HRIRPreset? {
        guard let id = profiles.currentProfile?.hrirPresetID else { return nil }
        return hrirManager.presets.first { $0.id == id }
    }
}
