import Foundation
import XCTest
@testable import Airwave

@MainActor
final class EqualizerLibraryTests: XCTestCase {
    func testBundledAssetsSeedIntoEmptyLibrary() throws {
        let context = try TestContext()
        let files = try ["Bass Booster", "Bass Reducer", "Treble Booster", "Treble Reducer", "Vocal Booster"].map {
            try context.writePreset(named: "\($0).txt", preamp: 1)
        }
        let manager = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope,
            bundledPresetCatalog: BundledPresetCatalog(equalizerFiles: files)
        )

        XCTAssertEqual(
            manager.presets.map(\.displayName),
            ["Bass Booster", "Bass Reducer", "Treble Booster", "Treble Reducer", "Vocal Booster"]
        )
        XCTAssertTrue(manager.presets.allSatisfy { $0.definition.preampDB == 1 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: context.managed,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "txt" }.count, 5)
    }

    func testBundledSeedingIsIdempotentAndDoesNotOverwriteExistingFiles() throws {
        let context = try TestContext()
        let sourceFile = try context.writePreset(named: "Bass Booster.txt", preamp: 1)
        let sourceFiles = [sourceFile]
        _ = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope,
            bundledPresetCatalog: BundledPresetCatalog(equalizerFiles: sourceFiles)
        )
        let managedFile = context.managed.appendingPathComponent("Bass Booster.txt")
        let originalBytes = try Data(contentsOf: managedFile)

        try Data("Preamp: 99 dB\n".utf8).write(to: managedFile)
        try FileManager.default.removeItem(at: context.managed.appendingPathComponent(".bundled-presets.json"))

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope,
            bundledPresetCatalog: BundledPresetCatalog(equalizerFiles: sourceFiles)
        )

        XCTAssertEqual(try Data(contentsOf: managedFile), Data("Preamp: 99 dB\n".utf8))
        XCTAssertEqual(relaunched.presets.first?.definition.preampDB, 99)
        XCTAssertNotEqual(try Data(contentsOf: managedFile), originalBytes)
    }

    func testDeletedBundledPresetDoesNotReturnAndNewBundledFilenameIsSeeded() throws {
        let context = try TestContext()
        let initialFiles = try ["Bass Booster", "Bass Reducer", "Treble Booster", "Treble Reducer"].map {
            try context.writePreset(named: "\($0).txt", preamp: 1)
        }
        let allFiles = initialFiles + [try context.writePreset(named: "Vocal Booster.txt", preamp: 1)]
        let manager = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope,
            bundledPresetCatalog: BundledPresetCatalog(equalizerFiles: initialFiles)
        )
        let deleted = try XCTUnwrap(manager.presets.first { $0.displayName == "Bass Booster" })
        XCTAssertTrue(manager.delete(deleted))

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope,
            bundledPresetCatalog: BundledPresetCatalog(equalizerFiles: allFiles)
        )

        XCTAssertNil(relaunched.presets.first { $0.displayName == "Bass Booster" })
        XCTAssertNotNil(relaunched.presets.first { $0.displayName == "Vocal Booster" })
    }

    func testEmptyLibraryDefaultsToNone() throws {
        let context = try TestContext()

        XCTAssertTrue(context.manager.presets.isEmpty)
        XCTAssertNil(context.manager.libraryError)
    }

    func testImportPersistsStableIDsAcrossRelaunchWithoutGlobalSelection() throws {
        let context = try TestContext()
        let alpha = try context.writePreset(named: "Alpha.TXT", preamp: 1)
        let zulu = try context.writePreset(named: "Zulu.txt", preamp: 2)

        let result = context.manager.importPresets([zulu, alpha], collisionPolicy: .reject)
        XCTAssertEqual(result.imported.map(\.displayName), ["Zulu", "Alpha"])
        XCTAssertEqual(context.manager.presets.map(\.displayName), ["Alpha", "Zulu"])

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertEqual(relaunched.presets.map(\.id), context.manager.presets.map(\.id))
        XCTAssertEqual(relaunched.presets.map(\.definition), context.manager.presets.map(\.definition))
    }

    func testInvalidManagedFileIsSkippedAndReported() throws {
        let context = try TestContext()
        let invalid = context.managed.appendingPathComponent("broken.txt")
        try Data("Include: other.txt\n".utf8).write(to: invalid)

        let manager = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertTrue(manager.presets.isEmpty)
        XCTAssertEqual(manager.libraryError?.filename, "broken.txt")
    }

    func testMissingManagedFileIsRemovedFromLibrary() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Selected.txt", preamp: 1)
        let imported = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        try FileManager.default.removeItem(at: imported.fileURL)

        let relaunched = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertTrue(relaunched.presets.isEmpty)
        XCTAssertEqual(relaunched.libraryError?.filename, "Selected.txt")
    }

    func testExternalManagedFolderChangesReloadLibrary() throws {
        let context = try TestContext(startWatcher: true)
        let external = context.managed.appendingPathComponent("External.txt")

        try Data("Preamp: 3 dB\n".utf8).write(to: external)
        waitForEqualizerPreset(named: "External", in: context.manager)
        XCTAssertEqual(context.manager.presets.first?.definition.preampDB, 3)

        try FileManager.default.removeItem(at: external)
        waitForEqualizerPreset(named: "External", in: context.manager, shouldExist: false)
        XCTAssertFalse(context.manager.presets.contains { $0.displayName == "External" })
    }

    func testPreflightAndBatchImportCopySourceAndBalanceSecurityScope() throws {
        let context = try TestContext()
        let valid = try context.writePreset(named: "Valid.txt", preamp: 1)
        let invalid = context.sourceDirectory.appendingPathComponent("invalid.txt")
        try Data("not an equalizer\n".utf8).write(to: invalid)

        let preflight = context.manager.preflightImport([invalid, valid])
        XCTAssertEqual(preflight.acceptable, [valid])
        XCTAssertEqual(preflight.rejected.count, 1)

        let sourceBytes = try Data(contentsOf: valid)
        let result = context.manager.importPresets([invalid, valid], collisionPolicy: .reject)
        XCTAssertEqual(result.imported.map(\.displayName), ["Valid"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: valid), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: context.managed.appendingPathComponent("Valid.txt")), sourceBytes)
        XCTAssertEqual(context.securityScope.startCount, 4)
        XCTAssertEqual(context.securityScope.stopCount, 4)
    }

    func testCollisionRejectAndReplacementPreserveIDAndReplaceAtomically() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let first = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        let originalBytes = try Data(contentsOf: first.fileURL)

        let replacementSource = try context.writePreset(named: "Curve.txt", preamp: 2)
        let preflight = context.manager.preflightImport([replacementSource])
        XCTAssertEqual(preflight.conflicts, [replacementSource])
        let rejected = context.manager.importPresets([replacementSource], collisionPolicy: .reject)
        XCTAssertEqual(rejected.skipped, ["Curve.txt"])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), originalBytes)
        XCTAssertEqual(context.manager.preset(id: first.id)?.definition.preampDB, 1)

        let replaced = context.manager.importPresets([replacementSource], collisionPolicy: .replace)
        XCTAssertEqual(replaced.imported.first?.id, first.id)
        XCTAssertEqual(context.manager.preset(id: first.id)?.definition.preampDB, 2)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), try Data(contentsOf: replacementSource))
        XCTAssertEqual(try Data(contentsOf: replacementSource), Data("Preamp: 2.0 dB\n".utf8))
    }

    func testFailedReplacementPreservesOldBytesAndDefinition() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let first = try XCTUnwrap(context.manager.importPresets([source], collisionPolicy: .reject).imported.first)
        let originalBytes = try Data(contentsOf: first.fileURL)

        let invalidReplacement = try context.writePreset(named: "Curve.txt", preamp: nil)
        let result = context.manager.importPresets([invalidReplacement], collisionPolicy: .replace)

        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), originalBytes)
        XCTAssertEqual(context.manager.preset(id: first.id)?.definition.preampDB, 1)
    }

    func testTraversalResistantBasenameAndSelectedDeletionLeaveSourceUntouched() throws {
        let context = try TestContext()
        let nested = context.sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = try context.writePreset(named: "Nested.txt", preamp: 1, directory: nested)
        let sourceBytes = try Data(contentsOf: source)
        let traversalURL = nested.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("Nested.txt")

        let imported = try XCTUnwrap(context.manager.importPresets([traversalURL], collisionPolicy: .reject).imported.first)
        XCTAssertEqual(imported.fileURL.deletingLastPathComponent().standardizedFileURL, context.managed.standardizedFileURL)
        XCTAssertTrue(context.manager.delete(imported))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertNil(context.manager.preset(id: imported.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.fileURL.path))
    }

    func testSymbolicLinkImportIsRejectedAndDoesNotEnterManagedLibrary() throws {
        let context = try TestContext()
        let target = try context.writePreset(named: "Target.txt", preamp: 1)
        let link = context.sourceDirectory.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = context.manager.importPresets([link], collisionPolicy: .reject)

        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.failures.first?.filename, "Link.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.managed.appendingPathComponent("Link.txt").path))
    }

    func testSettingsCoordinatorSuppressesSuccessfulActionsAndSkippedImports() throws {
        let context = try TestContext()
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)
        let coordinator = PresetLibraryCoordinator(manager: context.manager, configuration: .equalizer)

        coordinator.receive([source])
        let imported = try XCTUnwrap(context.manager.presets.first)
        XCTAssertNil(coordinator.message)

        coordinator.receive([source])
        XCTAssertEqual(coordinator.conflicts, [source])
        coordinator.resolveConflicts(.keepExisting)
        XCTAssertNil(coordinator.message)

        XCTAssertTrue(coordinator.delete(context.manager.libraryDeletion(for: imported), decision: .confirm))
        XCTAssertNil(coordinator.message)
    }

    func testSettingsCoordinatorRetainsMixedImportFailures() throws {
        let context = try TestContext()
        let valid = try context.writePreset(named: "Valid.txt", preamp: 1)
        let invalid = try context.writePreset(named: "Invalid.txt", preamp: nil)
        let coordinator = PresetLibraryCoordinator(manager: context.manager, configuration: .equalizer)

        coordinator.receive([invalid, valid])

        XCTAssertTrue(coordinator.message?.text.contains("Invalid.txt") == true)
        XCTAssertTrue(coordinator.message?.text.contains("unsupported directive") == true)
        XCTAssertEqual(context.manager.presets.map(\.displayName), ["Valid"])
    }

    func testCorruptManifestErrorIsPreservedAlongsideValidPresetRows() throws {
        let context = try TestContext()
        let valid = context.managed.appendingPathComponent("Valid.txt")
        try Data("Preamp: 1 dB\n".utf8).write(to: valid)
        try Data("{not-json".utf8).write(to: context.managed.appendingPathComponent("manifest.json"))

        let reloaded = EqualizerManager(
            managedDirectory: context.managed,
            fileManager: .default,
            defaults: context.defaults,
            securityScope: context.securityScope
        )

        XCTAssertEqual(reloaded.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(reloaded.libraryError?.filename, "manifest.json")
    }

    func testManifestWriteFailureRollsBackImportAndDeletion() throws {
        let writer = EqualizerManifestWriterFake()
        let context = try TestContext(manifestWriter: writer)
        let source = try context.writePreset(named: "Curve.txt", preamp: 1)

        writer.shouldFail = true
        let failedImport = context.manager.importPresets([source], collisionPolicy: .reject)
        XCTAssertTrue(failedImport.imported.isEmpty)
        XCTAssertTrue(context.manager.presets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.managed.appendingPathComponent("Curve.txt").path))

        writer.shouldFail = false
        let imported = try XCTUnwrap(
            context.manager.importPresets([source], collisionPolicy: .reject).imported.first
        )
        let originalBytes = try Data(contentsOf: imported.fileURL)

        writer.shouldFail = true
        XCTAssertFalse(context.manager.delete(imported))
        XCTAssertTrue(context.manager.presets.contains(imported))
        XCTAssertNotNil(context.manager.preset(id: imported.id))
        XCTAssertEqual(try Data(contentsOf: imported.fileURL), originalBytes)
    }
}

@MainActor
private final class TestContext {
    let root: URL
    let managed: URL
    let sourceDirectory: URL
    let defaults: UserDefaults
    let securityScope = EqualizerSecurityScopeFake()
    let manager: EqualizerManager
    private let defaultsSuiteName: String

    init(
        manifestWriter: EqualizerManifestWriting = DefaultEqualizerManifestWriter(),
        bundledPresetCatalog: BundledPresetCatalog? = nil,
        startWatcher: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        managed = root.appendingPathComponent("Equalizer Presets", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "EqualizerLibraryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        manager = EqualizerManager(
            managedDirectory: managed,
            fileManager: .default,
            defaults: defaults,
            securityScope: securityScope,
            manifestWriter: manifestWriter,
            bundledPresetCatalog: bundledPresetCatalog,
            startWatcher: startWatcher
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func writePreset(named name: String, preamp: Double?, directory: URL? = nil) throws -> URL {
        let directory = directory ?? sourceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let contents = preamp.map { "Preamp: \($0) dB\n" } ?? "Include: invalid\n"
        try Data(contents.utf8).write(to: url)
        return url
    }
}

@MainActor
private func waitForEqualizerPreset(
    named name: String,
    in manager: EqualizerManager,
    shouldExist: Bool = true
) {
    let deadline = Date().addingTimeInterval(3)
    while (manager.presets.contains { $0.displayName == name }) != shouldExist && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

private final class EqualizerManifestWriterFake: EqualizerManifestWriting {
    var shouldFail = false

    func write(_ data: Data, to url: URL) throws {
        if shouldFail {
            throw NSError(domain: "EqualizerLibraryTests", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class EqualizerSecurityScopeFake: EqualizerSecurityScopeAccessing {
    var startCount = 0
    var stopCount = 0

    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        startCount += 1
        return true
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        stopCount += 1
    }
}
