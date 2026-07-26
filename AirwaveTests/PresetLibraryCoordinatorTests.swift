import XCTest
@testable import Airwave

@MainActor
final class PresetLibraryCoordinatorTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/preset-library-tests/\(name)")
    }

    private func makeCoordinator(
        _ manager: PresetLibraryManagerFake
    ) -> PresetLibraryCoordinator {
        PresetLibraryCoordinator(manager: manager, configuration: .equalizer)
    }

    func testRejectedFilesSurfaceAsOneMessageAndNothingImports() {
        let manager = PresetLibraryManagerFake()
        let broken = url("broken.txt")
        manager.preflight = .init(acceptable: [], conflicts: [], rejected: [
            .init(filename: "broken.txt", reason: "unsupported directive")
        ])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([broken])

        XCTAssertEqual(coordinator.message?.text, "broken.txt: unsupported directive")
        XCTAssertEqual(manager.importCalls.count, 1)
        XCTAssertEqual(manager.importCalls.first?.urls, [])
        XCTAssertTrue(coordinator.conflicts.isEmpty)
    }

    func testConflictReplaceImportsWithReplacement() {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(acceptable: [], conflicts: [existing], rejected: [])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing])
        XCTAssertEqual(coordinator.conflicts, [existing])
        XCTAssertTrue(manager.importCalls.isEmpty)

        coordinator.resolveConflicts(.replace)

        XCTAssertEqual(manager.importCalls.count, 1)
        XCTAssertEqual(manager.importCalls.first?.urls, [existing])
        XCTAssertEqual(manager.importCalls.first?.replacing, true)
        XCTAssertTrue(coordinator.conflicts.isEmpty)
        XCTAssertNil(coordinator.message)
    }

    func testConflictKeepExistingImportsWithoutReplacement() {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(acceptable: [], conflicts: [existing], rejected: [])
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing])
        coordinator.resolveConflicts(.keepExisting)

        XCTAssertEqual(manager.importCalls.first?.replacing, false)
    }

    func testCancellingConflictsImportsNothingButKeepsPreflightFailures() {
        let manager = PresetLibraryManagerFake()
        let existing = url("Curve.txt")
        manager.preflight = .init(
            acceptable: [],
            conflicts: [existing],
            rejected: [.init(filename: "broken.txt", reason: "unsupported directive")]
        )
        let coordinator = makeCoordinator(manager)

        coordinator.receive([existing, url("broken.txt")])
        coordinator.resolveConflicts(.cancel)

        XCTAssertTrue(manager.importCalls.isEmpty)
        XCTAssertEqual(coordinator.message?.text, "broken.txt: unsupported directive")
        XCTAssertTrue(coordinator.conflicts.isEmpty)
    }

    func testDeleteConfirmDeletesAndClearsMessage() {
        let manager = PresetLibraryManagerFake()
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertTrue(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))

        XCTAssertEqual(manager.deleted, [preset])
        XCTAssertNil(coordinator.message)
    }

    func testDeleteCancelLeavesTheLibraryUntouched() {
        let manager = PresetLibraryManagerFake()
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .cancel))

        XCTAssertTrue(manager.deleted.isEmpty)
        XCTAssertNil(coordinator.message)
    }

    func testFailedDeleteReportsManagerDetailThenFallback() {
        let manager = PresetLibraryManagerFake()
        manager.deleteSucceeds = false
        manager.failureDetail = "Curve.txt: the managed file could not be read"
        let coordinator = makeCoordinator(manager)
        let preset = FakePreset(id: "Curve", name: "Curve")

        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))
        XCTAssertEqual(
            coordinator.message?.text,
            "Could not delete Curve.txt: the managed file could not be read"
        )

        manager.failureDetail = nil
        XCTAssertFalse(coordinator.delete(manager.libraryDeletion(for: preset), decision: .confirm))
        XCTAssertEqual(coordinator.message?.text, "Could not delete the managed preset.")
    }

    func testRowsPlaceNoneFirstAndSortOnlyWhenAsked() {
        let presets = [
            FakePreset(id: "b", name: "Zulu"),
            FakePreset(id: "a", name: "Alpha")
        ]

        let unsorted = PresetLibraryRowModel.rows(
            presets: presets, selectedID: "a", name: \.name, sortedByName: false
        )
        XCTAssertEqual(unsorted.map(\.name), ["None", "Zulu", "Alpha"])
        XCTAssertEqual(unsorted.map(\.isSelected), [false, false, true])

        let sorted = PresetLibraryRowModel.rows(
            presets: presets, selectedID: nil, name: \.name, sortedByName: true
        )
        XCTAssertEqual(sorted.map(\.name), ["None", "Alpha", "Zulu"])
        XCTAssertTrue(try XCTUnwrap(sorted.first).isSelected)
        XCTAssertTrue(PresetLibraryRowModel.rows(
            presets: [FakePreset](), selectedID: nil, name: \.name, sortedByName: true
        ).isEmpty)
    }
}

private struct FakePreset: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
private final class PresetLibraryManagerFake: PresetLibraryManaging {
    var preflight = PresetLibraryPreflight(acceptable: [], conflicts: [], rejected: [])
    var importFailures: [PresetLibraryFailure] = []
    var deleteSucceeds = true
    var failureDetail: String?
    private(set) var importCalls: [(urls: [URL], replacing: Bool)] = []
    private(set) var deleted: [FakePreset] = []
    private(set) var revealCount = 0

    func preflightLibraryImport(_ urls: [URL]) -> PresetLibraryPreflight { preflight }

    func importLibraryPresets(_ urls: [URL], replacingConflicts: Bool) -> [PresetLibraryFailure] {
        importCalls.append((urls, replacingConflicts))
        return importFailures
    }

    func deleteLibraryPreset(_ preset: FakePreset) -> Bool {
        guard deleteSucceeds else { return false }
        deleted.append(preset)
        return true
    }

    func deletionFailureDetail(for preset: FakePreset) -> String? { failureDetail }

    func revealLibraryDirectory() { revealCount += 1 }
}
