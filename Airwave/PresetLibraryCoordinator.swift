import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

nonisolated struct PresetLibraryFailure: Equatable {
    let filename: String
    let reason: String
}

nonisolated struct PresetLibraryPreflight {
    let acceptable: [URL]
    let conflicts: [URL]
    let rejected: [PresetLibraryFailure]
}

nonisolated struct PresetLibraryRow<Preset: Identifiable>: Identifiable {
    let id: String
    let name: String
    let preset: Preset?
    let isSelected: Bool
}

nonisolated enum PresetLibraryRowModel {
    /// "None" followed by the library, sorted only where the feature sorts today.
    static func rows<Preset: Identifiable>(
        presets: [Preset],
        selectedID: Preset.ID?,
        name: (Preset) -> String,
        sortedByName: Bool
    ) -> [PresetLibraryRow<Preset>] {
        guard !presets.isEmpty else { return [] }
        let ordered = sortedByName
            ? presets.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
            : presets
        return [PresetLibraryRow(
            id: "none",
            name: "None",
            preset: nil,
            isSelected: selectedID == nil
        )] + ordered.map { preset in
            PresetLibraryRow(
                id: String(describing: preset.id),
                name: name(preset),
                preset: preset,
                isSelected: selectedID == preset.id
            )
        }
    }
}

nonisolated enum PresetLibraryConflictResolution {
    case replace
    case keepExisting
    case cancel
}

nonisolated enum PresetLibraryDeletionDecision {
    case confirm
    case cancel
}

nonisolated struct PresetLibraryMessage: Equatable {
    let text: String
}

/// What one preset library needs to expose for the shared import/delete flow.
/// Managers keep their own APIs; adapters below map them onto this.
protocol PresetLibraryManaging: AnyObject {
    associatedtype Preset: Identifiable & Equatable

    func preflightLibraryImport(_ urls: [URL]) -> PresetLibraryPreflight
    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) -> [PresetLibraryFailure]
    func deleteLibraryPreset(_ preset: Preset) -> Bool
    /// "<name>: <reason>" describing the last delete failure, if the manager has one.
    func deletionFailureDetail(for preset: Preset) -> String?
    func revealLibraryDirectory()
}

/// The per-feature strings and file types; everything else is shared.
nonisolated struct PresetLibraryConfiguration {
    let contentType: UTType
    let panelTitle: String
    let panelMessage: String
    let deletionFailureFallback: String

    static let hrir = PresetLibraryConfiguration(
        contentType: UTType(filenameExtension: "wav") ?? .audio,
        panelTitle: "Import HRIR Presets",
        panelMessage: "Choose one or more compatible HRIR WAV files.",
        deletionFailureFallback: "Could not delete the managed HRIR preset."
    )

    static let equalizer = PresetLibraryConfiguration(
        contentType: UTType(filenameExtension: "txt") ?? .plainText,
        panelTitle: "Import Equalizer Presets",
        panelMessage: "Choose one or more EqualizerAPO .txt preset files.",
        deletionFailureFallback: "Could not delete the managed preset."
    )
}

/// One preset's deletion, captured so the coordinator itself stays non-generic
/// (a generic ObservableObject class crashes the Swift 6.3.3 SIL optimizer).
nonisolated struct PresetLibraryDeletion {
    let perform: () -> Bool
    /// "<name>: <reason>" for the failure, read after `perform` returns false.
    let failureDetail: () -> String?
}

/// Import, conflict resolution, and deletion for any preset library.
@MainActor
final class PresetLibraryCoordinator: ObservableObject {
    @Published private(set) var conflicts: [URL] = []
    @Published private(set) var message: PresetLibraryMessage?

    let configuration: PresetLibraryConfiguration
    private let preflight: ([URL]) -> PresetLibraryPreflight
    private let performImport: ([URL], Bool) -> [PresetLibraryFailure]
    private let reveal: () -> Void
    private var pendingURLs: [URL] = []
    private var pendingFailures: [PresetLibraryFailure] = []

    init<Manager: PresetLibraryManaging>(
        manager: Manager,
        configuration: PresetLibraryConfiguration
    ) {
        self.configuration = configuration
        self.preflight = { manager.preflightLibraryImport($0) }
        self.performImport = { manager.importLibraryPresets($0, replacingConflicts: $1) }
        self.reveal = { manager.revealLibraryDirectory() }
    }

    func receive(_ urls: [URL]) {
        message = nil
        conflicts = []
        pendingURLs = []
        pendingFailures = []
        guard !urls.isEmpty else { return }

        let preflight = preflight(urls)
        let validURLs = urls.filter { url in
            preflight.acceptable.contains(url) || preflight.conflicts.contains(url)
        }
        pendingFailures = preflight.rejected

        if preflight.conflicts.isEmpty {
            importURLs(validURLs, replacingConflicts: false, preflightFailures: pendingFailures)
        } else {
            pendingURLs = validURLs
            conflicts = preflight.conflicts
        }
    }

    func resolveConflicts(_ resolution: PresetLibraryConflictResolution) {
        guard !conflicts.isEmpty else { return }
        let urls = pendingURLs
        let failures = pendingFailures
        pendingURLs = []
        pendingFailures = []
        conflicts = []

        switch resolution {
        case .replace:
            importURLs(urls, replacingConflicts: true, preflightFailures: failures)
        case .keepExisting:
            importURLs(urls, replacingConflicts: false, preflightFailures: failures)
        case .cancel:
            message = makeMessage(failures: failures)
        }
    }

    func dismissMessage() {
        message = nil
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [configuration.contentType]
        panel.title = configuration.panelTitle
        panel.message = configuration.panelMessage
        // Non-modal: the settings window keeps drawing while the panel is up.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.receive(panel.urls) }
        }
    }

    func showInFinder() {
        reveal()
    }

    @discardableResult
    func delete(
        _ deletion: PresetLibraryDeletion,
        decision: PresetLibraryDeletionDecision
    ) -> Bool {
        guard decision == .confirm else { return false }
        guard deletion.perform() else {
            message = PresetLibraryMessage(
                text: deletion.failureDetail().map { "Could not delete \($0)" }
                    ?? configuration.deletionFailureFallback
            )
            return false
        }
        message = nil
        return true
    }

    private func importURLs(
        _ urls: [URL],
        replacingConflicts: Bool,
        preflightFailures: [PresetLibraryFailure] = []
    ) {
        let failures = performImport(urls, replacingConflicts)
        message = makeMessage(failures: preflightFailures + failures)
    }

    private func makeMessage(failures: [PresetLibraryFailure]) -> PresetLibraryMessage? {
        guard !failures.isEmpty else { return nil }
        return PresetLibraryMessage(
            text: failures.map { "\($0.filename): \($0.reason)" }.joined(separator: " • ")
        )
    }
}

extension PresetLibraryManaging {
    /// Deletion of one preset, bound to this manager.
    func libraryDeletion(for preset: Preset) -> PresetLibraryDeletion {
        PresetLibraryDeletion(
            perform: { self.deleteLibraryPreset(preset) },
            failureDetail: { self.deletionFailureDetail(for: preset) }
        )
    }
}

// MARK: - Manager adapters

extension HRIRManager: PresetLibraryManaging {
    func preflightLibraryImport(_ urls: [URL]) -> PresetLibraryPreflight {
        let preflight = preflightImport(urls)
        return PresetLibraryPreflight(
            acceptable: preflight.acceptable,
            conflicts: preflight.conflicts,
            rejected: preflight.rejected.map { .init(filename: $0.filename, reason: $0.reason) }
        )
    }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) -> [PresetLibraryFailure] {
        importPresets(urls, collisionPolicy: replacingConflicts ? .replace : .reject)
            .failures
            .map { .init(filename: $0.filename, reason: $0.reason) }
    }

    func deleteLibraryPreset(_ preset: HRIRPreset) -> Bool { deletePreset(preset) }

    func deletionFailureDetail(for preset: HRIRPreset) -> String? {
        errorMessage.map { "\(preset.name): \($0)" }
    }

    func revealLibraryDirectory() { openPresetsDirectory() }
}

extension EqualizerManager: PresetLibraryManaging {
    func preflightLibraryImport(_ urls: [URL]) -> PresetLibraryPreflight {
        let preflight = preflightImport(urls)
        return PresetLibraryPreflight(
            acceptable: preflight.acceptable,
            conflicts: preflight.conflicts,
            rejected: preflight.rejected.map { .init(filename: $0.filename, reason: $0.reason) }
        )
    }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) -> [PresetLibraryFailure] {
        importPresets(urls, collisionPolicy: replacingConflicts ? .replace : .reject)
            .failures
            .map { .init(filename: $0.filename, reason: $0.reason) }
    }

    func deleteLibraryPreset(_ preset: EqualizerPreset) -> Bool { delete(preset) }

    func deletionFailureDetail(for preset: EqualizerPreset) -> String? {
        libraryError.map { "\($0.filename): \($0.reason)" }
    }

    func revealLibraryDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([managedDirectory])
    }
}
