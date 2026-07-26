import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct EqualizerSettingsView: View {
    @ObservedObject private var manager: EqualizerManager
    @ObservedObject private var profiles = DeviceProfileManager.shared
    @StateObject private var coordinator: PresetLibraryCoordinator
    private let actions: MenuBarViewModel

    @MainActor
    init(manager: EqualizerManager, actions: MenuBarViewModel) {
        _manager = ObservedObject(wrappedValue: manager)
        self.actions = actions
        _coordinator = StateObject(wrappedValue: PresetLibraryCoordinator(
            manager: manager,
            configuration: .equalizer
        ))
    }

    @MainActor
    init() {
        self.init(manager: .shared, actions: .shared)
    }

    var body: some View {
        PresetLibraryView(
            coordinator: coordinator,
            chrome: .equalizer,
            selectedPreset: selectedPreset,
            presetName: \.displayName,
            deletion: { [manager] preset in manager.libraryDeletion(for: preset) }
        ) {
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        if manager.presets.isEmpty {
            AirwaveEmptyLibraryState(
                systemImage: "slider.horizontal.3",
                title: "No equalizer presets",
                description: "Airwave normally ships five EQ presets. Import an EqualizerAPO .txt preset to add another profile."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(PresetLibraryRowModel.rows(
                        presets: manager.presets,
                        selectedID: profiles.editingProfile?.equalizerPresetID,
                        name: \.displayName,
                        sortedByName: false
                    )) { row in
                        Button {
                            actions.selectEditingEqualizerPreset(row.preset?.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(row.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if row.isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
                            .padding(.vertical, AirwaveLayout.rowVerticalPadding)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            row.isSelected ? AirwavePalette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .accessibilityValue(row.isSelected ? "Selected" : "Not selected")
                    }
                }
                .padding(6)
            }
        }
    }

    private var selectedPreset: EqualizerPreset? {
        manager.preset(id: profiles.editingProfile?.equalizerPresetID)
    }
}
