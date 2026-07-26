import SwiftUI

struct AirwavePresetList: View {
    let presets: [HRIRPreset]
    let selectedID: UUID?
    let onSelect: (HRIRPreset?) -> Void

    var body: some View {
        ZStack {
            if presets.isEmpty {
                AirwaveEmptyLibraryState(
                    systemImage: "waveform",
                    title: "No HRIR presets",
                    description: "Airwave normally ships NeutralSH1.0, RoomSH1.0, and StageSH1.0. Import a compatible WAV file to add another spatial profile."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(PresetLibraryRowModel.rows(
                            presets: presets,
                            selectedID: selectedID,
                            name: \.name,
                            sortedByName: true
                        )) { row in
                            selectionRow(row.name, selected: row.isSelected) { onSelect(row.preset) }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
            .padding(.vertical, AirwaveLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? AirwavePalette.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AirwaveHRIRPicker: View {
    @ObservedObject private var manager: HRIRManager
    let selectedID: UUID?
    let onSelect: (HRIRPreset?) -> Void
    let onDelete: (HRIRPreset) -> Void

    @StateObject private var coordinator: PresetLibraryCoordinator

    @MainActor
    init(
        manager: HRIRManager,
        selectedID: UUID?,
        onSelect: @escaping (HRIRPreset?) -> Void,
        onDelete: @escaping (HRIRPreset) -> Void = { _ in }
    ) {
        _manager = ObservedObject(wrappedValue: manager)
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onDelete = onDelete
        _coordinator = StateObject(wrappedValue: PresetLibraryCoordinator(
            manager: manager,
            configuration: .hrir
        ))
    }

    var body: some View {
        PresetLibraryView(
            coordinator: coordinator,
            chrome: .hrir,
            selectedPreset: selectedPreset,
            presetName: \.name,
            deletion: { [manager] preset in manager.libraryDeletion(for: preset) },
            onDeleted: onDelete
        ) {
            AirwavePresetList(
                presets: manager.presets,
                selectedID: selectedID,
                onSelect: onSelect
            )
        }
    }

    private var selectedPreset: HRIRPreset? {
        manager.presets.first { $0.id == selectedID }
    }
}
