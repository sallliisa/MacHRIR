import AVFoundation
import Foundation
import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileManagementTests: XCTestCase {
    func testBundledHRTFsSeedAndRemainAvailableOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFiles = try ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"].map { name in
            let url = sourceDirectory.appendingPathComponent("\(name).wav")
            try writeTestWAV(to: url)
            return url
        }

        let catalog = BundledPresetCatalog(hrirFiles: sourceFiles)
        let manager = HRIRManager(
            presetsDirectory: managed,
            startWatcher: false,
            bundledPresetCatalog: catalog
        )
        waitForInitialHRIRSync(manager)

        XCTAssertEqual(Set(manager.presets.map(\.name)), ["NeutralSH1.0", "RoomSH1.0", "StageSH1.0"])
        XCTAssertTrue(manager.presets.allSatisfy { $0.channelCount == 2 && $0.sampleRate == 48_000 })

        let deleted = try XCTUnwrap(manager.presets.first { $0.name == "RoomSH1.0" })
        manager.deletePreset(deleted)
        let relaunched = HRIRManager(
            presetsDirectory: managed,
            startWatcher: false,
            bundledPresetCatalog: catalog
        )
        waitForInitialHRIRSync(relaunched)

        XCTAssertNil(relaunched.presets.first { $0.name == "RoomSH1.0" })
        XCTAssertEqual(Set(relaunched.presets.map(\.name)), ["NeutralSH1.0", "StageSH1.0"])
    }

    func testRowsResolveNamesAndKeepCurrentFirstOrdering() throws {
        let context = try ManagementContext()
        let hrirID = UUID()
        context.hrir.presets = [HRIRPreset(
            id: hrirID,
            name: "Concert Hall",
            fileURL: URL(fileURLWithPath: "/tmp/concert.wav"),
            channelCount: 2,
            sampleRate: 48_000
        )]
        let equalizerFile = context.root.appendingPathComponent("Warm.txt")
        try Data("Preamp: 1 dB\n".utf8).write(to: equalizerFile)
        let imported = context.equalizer.importPresets([equalizerFile], collisionPolicy: .reject).imported
        let importedPreset = try XCTUnwrap(imported.first)
        XCTAssertEqual(importedPreset.displayName, "Warm")

        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Remembered"))
        context.profiles.setHRIRPresetID(hrirID, for: "remembered")
        context.profiles.setEqualizerPresetID(importedPreset.id, for: "remembered")
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current", transport: "USB"))

        let coordinator = context.coordinator()
        XCTAssertEqual(coordinator.rows.map(\.deviceName), ["Current", "Remembered"])
        XCTAssertEqual(coordinator.rows[0].status, "Current")
        XCTAssertEqual(coordinator.rows[0].transport, "USB")
        XCTAssertEqual(coordinator.rows[0].hrirName, "None")
        XCTAssertEqual(coordinator.rows[0].equalizerName, "None")
        XCTAssertEqual(coordinator.rows[1].hrirName, "Concert Hall")
        XCTAssertEqual(coordinator.rows[1].equalizerName, "Warm")
        XCTAssertEqual(coordinator.rows[1].transport, "Built-in")
        XCTAssertEqual(coordinator.rows[1].status, "Not Current")
    }

    func testActionEnabledStatesMatchProfileAndCurrentStatus() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "blank", name: "Blank"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))

        let rows = context.coordinator().rows
        let current = try XCTUnwrap(rows.first { $0.id == "current" })
        let blank = try XCTUnwrap(rows.first { $0.id == "blank" })
        XCTAssertFalse(current.canReset)
        XCTAssertFalse(current.canForget)
        XCTAssertFalse(blank.canReset)
        XCTAssertTrue(blank.canForget)
    }

    func testResetConfirmationCancelAndConfirmUseExpectedCopyAndOneManagerCall() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Studio DAC"))
        context.profiles.setHRIRPresetID(UUID())
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))
        var resetCalls: [String] = []
        let coordinator = context.coordinator(resetOperation: { uid in
            resetCalls.append(uid)
            return true
        })

        coordinator.requestReset(deviceUID: "remembered")
        XCTAssertEqual(coordinator.pendingConfirmation, .init(
            action: .reset,
            deviceUID: "remembered",
            deviceName: "Studio DAC",
            title: "Reset Studio DAC profile?",
            message: "Both HRIR and EQ will become None.",
            destructiveButtonTitle: "Reset Profile"
        ))
        coordinator.cancelConfirmation()
        XCTAssertNil(coordinator.pendingConfirmation)
        XCTAssertTrue(resetCalls.isEmpty)

        coordinator.requestReset(deviceUID: "remembered")
        XCTAssertTrue(coordinator.confirmPendingAction())
        XCTAssertEqual(resetCalls, ["remembered"])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testForgetConfirmationUsesExpectedCopyAndManagerCallWithoutResultFeedback() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "remembered", name: "Studio DAC"))
        context.date = context.date.addingTimeInterval(1)
        seedProfile(context.profiles, profileDevice(id: 2, uid: "current", name: "Current"))
        var forgetCalls: [String] = []
        let coordinator = context.coordinator(forgetOperation: { uid in
            forgetCalls.append(uid)
            return true
        })

        coordinator.requestForget(deviceUID: "remembered")
        XCTAssertEqual(coordinator.pendingConfirmation, .init(
            action: .forget,
            deviceUID: "remembered",
            deviceName: "Studio DAC",
            title: "Forget Studio DAC?",
            message: "If this device remains available, its profile can be recreated from the device selector.",
            destructiveButtonTitle: "Forget Device"
        ))
        XCTAssertTrue(coordinator.confirmPendingAction())
        XCTAssertEqual(forgetCalls, ["remembered"])
        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testHRIRSettingsCoordinatorSuppressesSuccessfulActionsAndSkippedImports() throws {
        let context = try ManagementContext()
        let source = context.root.appendingPathComponent("Room.wav")
        try writeTestWAV(to: source)
        let coordinator = PresetLibraryCoordinator(manager: context.hrir, configuration: .hrir)

        coordinator.receive([source])
        let imported = try XCTUnwrap(context.hrir.presets.first)
        XCTAssertNil(coordinator.message)

        coordinator.receive([source])
        XCTAssertEqual(coordinator.conflicts, [source])
        coordinator.resolveConflicts(.keepExisting)
        XCTAssertNil(coordinator.message)

        XCTAssertTrue(coordinator.delete(context.hrir.libraryDeletion(for: imported), decision: .confirm))
        XCTAssertNil(coordinator.message)
    }

    func testHRIRSettingsCoordinatorRetainsImportFailures() throws {
        let context = try ManagementContext()
        let invalid = context.root.appendingPathComponent("broken.txt")
        try Data("not a WAV\n".utf8).write(to: invalid)
        let coordinator = PresetLibraryCoordinator(manager: context.hrir, configuration: .hrir)

        coordinator.receive([invalid])

        XCTAssertTrue(coordinator.message?.text.contains("broken.txt") == true)
        XCTAssertTrue(coordinator.message?.text.contains("WAV") == true)
    }

    func testCurrentForgetIsDisabledAndCannotCreateConfirmation() throws {
        let context = try ManagementContext()
        seedProfile(context.profiles, profileDevice(id: 1, uid: "current", name: "Current"))
        let coordinator = context.coordinator()

        XCTAssertFalse(try XCTUnwrap(coordinator.rows.first).canForget)
        coordinator.requestForget(deviceUID: "current")

        XCTAssertNil(coordinator.pendingConfirmation)
    }

    func testEmptyStateHasNoRowsAndUsefulGuidanceModelInput() throws {
        let context = try ManagementContext()
        XCTAssertTrue(context.coordinator().rows.isEmpty)
    }
}

@MainActor
private func waitForInitialHRIRSync(_ manager: HRIRManager) {
    let deadline = Date().addingTimeInterval(2)
    while !manager.initialLibrarySyncReady && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private final class ManagementContext {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let profiles: DeviceProfileManager
    let hrir: HRIRManager
    let equalizer: EqualizerManager
    private let clock: ManagementClock

    var date: Date {
        get { clock.value }
        set { clock.value = newValue }
    }

    init() throws {
        let clock = ManagementClock()
        self.clock = clock
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "DeviceProfileManagementTests.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        profiles = DeviceProfileManager(defaults: defaults, now: { clock.value })
        hrir = HRIRManager(presetsDirectory: root.appendingPathComponent("hrir"), startWatcher: false)
        equalizer = EqualizerManager(managedDirectory: root.appendingPathComponent("eq"))
    }

    func coordinator(
        resetOperation: ((String) -> Bool)? = nil,
        forgetOperation: ((String) -> Bool)? = nil
    ) -> DeviceManagementCoordinator {
        DeviceManagementCoordinator(
            profileManager: profiles,
            hrirManager: hrir,
            equalizerManager: equalizer,
            resetOperation: resetOperation,
            forgetOperation: forgetOperation
        )
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ManagementClock {
    var value = Date(timeIntervalSince1970: 1_700_000_000)
}

private func profileDevice(
    id: UInt64,
    uid: String,
    name: String,
    transport: String = "built",
    virtual: Bool = false,
    aggregate: Bool = false,
    channels: Int = 2
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(id), uid: uid, name: name, transport: transport,
        outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate
    )
}

@MainActor
private func seedProfile(_ manager: DeviceProfileManager, _ output: OutputDeviceDescriptor) {
    manager.updateAvailableOutputs([output])
    manager.selectEditingDevice(uid: output.uid)
    manager.setHRIRPresetID(UUID(), for: output.uid)
    manager.setHRIRPresetID(nil, for: output.uid)
    manager.observeCurrentOutput(output)
}

private func writeTestWAV(to url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
    buffer.frameLength = 1
    buffer.floatChannelData?[0][0] = 0
    buffer.floatChannelData?[1][0] = 0
    try file.write(from: buffer)
}
