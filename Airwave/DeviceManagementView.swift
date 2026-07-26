import Combine
import SwiftUI

nonisolated enum DeviceManagementAction: Equatable {
    case reset
    case forget
}

nonisolated struct DeviceManagementRow: Equatable, Identifiable {
    let id: String
    let deviceName: String
    let transport: String
    let status: String
    let hrirName: String
    let equalizerName: String
    let canReset: Bool
    let canForget: Bool
}

nonisolated struct DeviceManagementConfirmation: Equatable {
    let action: DeviceManagementAction
    let deviceUID: String
    let deviceName: String
    let title: String
    let message: String
    let destructiveButtonTitle: String
}

@MainActor
final class DeviceManagementCoordinator: ObservableObject {
    @Published private(set) var pendingConfirmation: DeviceManagementConfirmation?
    /// Cached so a render pass never rebuilds the list, and so callers can
    /// observe row changes instead of diffing a computed property.
    @Published private(set) var rows: [DeviceManagementRow] = []
    /// Fires when a cache rebuild dropped the row a caller had selected.
    var onRowsInvalidatedSelection: ((String) -> Void)?

    private let profileManager: DeviceProfileManager
    private let hrirManager: HRIRManager
    private let equalizerManager: EqualizerManager
    private let resetOperation: (String) -> Bool
    private let forgetOperation: (String) -> Bool
    private var cancellables: Set<AnyCancellable> = []

    init(
        profileManager: DeviceProfileManager,
        hrirManager: HRIRManager,
        equalizerManager: EqualizerManager,
        resetOperation: ((String) -> Bool)? = nil,
        forgetOperation: ((String) -> Bool)? = nil
    ) {
        self.profileManager = profileManager
        self.hrirManager = hrirManager
        self.equalizerManager = equalizerManager
        self.resetOperation = resetOperation ?? { [weak profileManager] uid in
            profileManager?.resetProfile(deviceUID: uid) ?? false
        }
        self.forgetOperation = forgetOperation ?? { [weak profileManager] uid in
            profileManager?.forgetProfile(deviceUID: uid) ?? false
        }
        rebuildRows()
        profileManager.objectWillChange
            .merge(with: hrirManager.objectWillChange, equalizerManager.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)
    }

    private func rebuildRows() {
        let rebuilt = makeRows()
        guard rebuilt != rows else { return }
        rows = rebuilt
    }

    private func makeRows() -> [DeviceManagementRow] {
        profileManager.sortedProfiles.map { profile in
            let hrirName = profile.hrirPresetID.flatMap { id in
                hrirManager.presets.first { $0.id == id }?.name
            } ?? "None"
            let equalizerName = profile.equalizerPresetID.flatMap { id in
                equalizerManager.presets.first { $0.id == id }?.displayName
            } ?? "None"
            return DeviceManagementRow(
                id: profile.deviceUID,
                deviceName: profile.deviceName,
                transport: displayTransport(profile.transport),
                status: profile.deviceUID == profileManager.currentDeviceUID ? "Current" : "Not Current",
                hrirName: hrirName,
                equalizerName: equalizerName,
                canReset: profile.hrirPresetID != nil || profile.equalizerPresetID != nil,
                canForget: profile.deviceUID != profileManager.currentDeviceUID
            )
        }
    }

    private func displayTransport(_ transport: String) -> String {
        switch transport.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "buil", "built", "built-in", "builtin": "Built-in"
        case "blth", "bluetooth": "Bluetooth"
        case "usb": "USB"
        case "fire", "firewire": "FireWire"
        case "dprt", "displayport": "DisplayPort"
        case "hdmi": "HDMI"
        case "thun", "thunderbolt": "Thunderbolt"
        case "airp", "airplay": "AirPlay"
        case "virt", "virtual": "Virtual"
        case "grup", "aggregate": "Aggregate"
        default: transport.isEmpty ? "Unknown transport" : transport
        }
    }

    func requestReset(deviceUID: String) {
        guard let row = rows.first(where: { $0.id == deviceUID }), row.canReset else { return }
        pendingConfirmation = DeviceManagementConfirmation(
            action: .reset,
            deviceUID: row.id,
            deviceName: row.deviceName,
            title: "Reset " + row.deviceName + " profile?",
            message: "Both HRIR and EQ will become None.",
            destructiveButtonTitle: "Reset Profile"
        )
    }

    func requestForget(deviceUID: String) {
        guard let row = rows.first(where: { $0.id == deviceUID }), row.canForget else { return }
        pendingConfirmation = DeviceManagementConfirmation(
            action: .forget,
            deviceUID: row.id,
            deviceName: row.deviceName,
            title: "Forget " + row.deviceName + "?",
            message: "If this device remains available, its profile can be recreated from the device selector.",
            destructiveButtonTitle: "Forget Device"
        )
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    @discardableResult
    func confirmPendingAction() -> Bool {
        guard let confirmation = pendingConfirmation else { return false }
        pendingConfirmation = nil

        defer { rebuildRows() }
        switch confirmation.action {
        case .reset:
            return resetOperation(confirmation.deviceUID)
        case .forget:
            return forgetOperation(confirmation.deviceUID)
        }
    }
}

struct DeviceManagementView: View {
    @StateObject private var coordinator: DeviceManagementCoordinator
    @State private var selectedDeviceUID: String?

    init(
        profileManager: DeviceProfileManager,
        hrirManager: HRIRManager,
        equalizerManager: EqualizerManager
    ) {
        _coordinator = StateObject(wrappedValue: DeviceManagementCoordinator(
            profileManager: profileManager,
            hrirManager: hrirManager,
            equalizerManager: equalizerManager
        ))
    }

    @MainActor
    init() {
        self.init(
            profileManager: .shared,
            hrirManager: .shared,
            equalizerManager: .shared
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AirwaveLayout.sectionContentSpacing) {
            VStack(spacing: 0) {
                ZStack {
                    if coordinator.rows.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(coordinator.rows) { row in
                                    deviceRow(row)
                                    if row.id != coordinator.rows.last?.id {
                                        Divider().padding(.leading, 16)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                actionFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AirwavePalette.raised, in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius))
        }
        .onAppear { selectedDeviceUID = nil }
        .onChange(of: coordinator.rows) { _, rows in
            // The cache rebuilt; drop a selection whose device is gone.
            if let selectedDeviceUID, !rows.contains(where: { $0.id == selectedDeviceUID }) {
                self.selectedDeviceUID = nil
            }
        }
        .confirmationDialog(
            coordinator.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { coordinator.pendingConfirmation != nil },
                set: { isPresented in
                    if !isPresented { coordinator.cancelConfirmation() }
                }
            )
        ) {
            if let confirmation = coordinator.pendingConfirmation {
                Button(confirmation.destructiveButtonTitle, role: .destructive) {
                    coordinator.confirmPendingAction()
                }
            }
            Button("Cancel", role: .cancel, action: coordinator.cancelConfirmation)
        } message: {
            if let confirmation = coordinator.pendingConfirmation {
                Text(confirmation.message)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No remembered devices")
                .font(.system(size: 13, weight: .semibold))
            Text("Supported stereo outputs will appear here after Airwave sees them.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(AirwaveLayout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No remembered devices. Supported stereo outputs will appear here after Airwave sees them.")
    }

    private func deviceRow(_ row: DeviceManagementRow) -> some View {
        Button {
            selectedDeviceUID = row.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(row.transport) · \(row.status)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("HRIR: \(row.hrirName)")
                    Text("EQ: \(row.equalizerName)")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedDeviceUID == row.id
                ? AirwavePalette.hover
                : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityAddTraits(selectedDeviceUID == row.id ? .isSelected : [])
        .accessibilityValue(selectedDeviceUID == row.id ? "Selected" : "Not selected")
    }

    private var selectedRow: DeviceManagementRow? {
        guard let selectedDeviceUID else { return nil }
        return coordinator.rows.first { $0.id == selectedDeviceUID }
    }

    private var actionFooter: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Reset Profile") {
                if let selectedDeviceUID {
                    coordinator.requestReset(deviceUID: selectedDeviceUID)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedRow?.canReset != true)
            .accessibilityLabel(
                selectedRow.map { "Reset Profile for \($0.deviceName)" } ?? "Reset Profile"
            )
            Button("Forget Device") {
                if let selectedDeviceUID {
                    coordinator.requestForget(deviceUID: selectedDeviceUID)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedRow?.canForget != true)
            .accessibilityLabel(
                selectedRow.map { "Forget \($0.deviceName)" } ?? "Forget Device"
            )
        }
        .padding(AirwaveLayout.cardPadding)
    }
}
