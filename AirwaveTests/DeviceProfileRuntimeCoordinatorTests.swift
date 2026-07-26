import AVFoundation
import XCTest
@testable import Airwave

@MainActor
final class DeviceProfileRuntimeCoordinatorTests: XCTestCase {
    func testNewDeviceCompletesWithOneEmptyPairAndCreatesBypassedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Coordinator.\(UUID().uuidString)"))
        let profiles = DeviceProfileManager(defaults: defaults)
        let hrir = HRIRManager(presetsDirectory: root.appendingPathComponent("hrir"), startWatcher: false)
        let equalizer = EqualizerManager(managedDirectory: root.appendingPathComponent("eq"))
        let platform = CoordinatorPlatformFake()
        let controller = AudioRuntimeController(
            state: AudioRuntimeState(), platform: platform,
            pipelineFactory: { CoordinatorPipelineFake() },
            scheduler: CoordinatorSchedulerFake()
        )
        let coordinator = DeviceProfileRuntimeCoordinator(
            profiles: profiles, hrir: hrir, equalizer: equalizer, controller: controller
        )
        let output = OutputDeviceDescriptor(
            id: .init(7), uid: "headphones", name: "Headphones", transport: "USB",
            outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
        var result: AudioRuntimeEffectReadiness?

        coordinator.prepare(output: output) { result = $0 }

        XCTAssertEqual(result, .init(spatialReady: false, equalizerDefinition: nil))
        XCTAssertEqual(profiles.currentDeviceUID, "headphones")
        XCTAssertNil(profiles.currentProfile?.hrirPresetID)
        XCTAssertNil(profiles.currentProfile?.equalizerPresetID)
    }

    func testHRIRChangeWhileProcessingSwapsPresetWithoutRestartingThePipeline() async throws {
        let context = try await SpatialContext()
        let second = try XCTUnwrap(context.hrir.presets.last)

        context.profiles.setCurrentHRIRPresetID(second.id)
        try await context.wait { context.hrir.activePreset?.id == second.id }

        XCTAssertEqual(context.pipelines.purposes, [.processing])
        XCTAssertEqual(context.pipelines.liveCount, 1)
        XCTAssertEqual(context.state.status, .processing)
    }

    func testHRIRChangeWhileNotProcessingDoesNotActivateLive() async throws {
        let context = try await SpatialContext()
        let second = try XCTUnwrap(context.hrir.presets.last)
        context.controller.willSleep()
        XCTAssertEqual(context.pipelines.liveCount, 0)

        context.profiles.setCurrentHRIRPresetID(second.id)
        try await context.settle()

        XCTAssertNil(context.hrir.activePreset)
        XCTAssertEqual(context.pipelines.purposes, [.processing])
    }

    func testFailedLiveActivationFallsBackToFullRestart() async throws {
        let context = try await SpatialContext()
        let second = try XCTUnwrap(context.hrir.presets.last)
        try FileManager.default.removeItem(at: second.fileURL)

        context.profiles.setCurrentHRIRPresetID(second.id)
        try await context.wait { context.hrir.errorMessage != nil }
        try await context.settle()

        XCTAssertNil(context.hrir.activePreset)
        XCTAssertEqual(context.pipelines.liveCount, 0)
        guard case .nativePassthrough = context.state.status else {
            return XCTFail("expected passthrough after a failed activation")
        }
    }

    func testRemovingTheOnlyEffectStopsTheProcessingPipeline() async throws {
        let context = try await SpatialContext()

        context.profiles.setCurrentHRIRPresetID(nil)
        try await context.settle()

        XCTAssertNil(context.hrir.activePreset)
        XCTAssertEqual(context.pipelines.liveCount, 0)
        XCTAssertEqual(context.state.status, .inactive)
    }
}

/// A launched coordinator processing audio on a supported output with two
/// importable HRIR presets.
@MainActor
private final class SpatialContext {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let profiles: DeviceProfileManager
    let hrir: HRIRManager
    let equalizer: EqualizerManager
    let state = AudioRuntimeState()
    let pipelines = CoordinatorPipelineFactoryFake()
    let controller: AudioRuntimeController
    let coordinator: DeviceProfileRuntimeCoordinator
    static let output = OutputDeviceDescriptor(
        id: .init(7), uid: "headphones", name: "Headphones", transport: "USB",
        outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
    )

    init() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Coordinator.\(UUID().uuidString)"))
        profiles = DeviceProfileManager(defaults: defaults)
        hrir = HRIRManager(presetsDirectory: root.appendingPathComponent("hrir"), startWatcher: false)
        equalizer = EqualizerManager(managedDirectory: root.appendingPathComponent("eq"))
        controller = AudioRuntimeController(
            state: state,
            platform: CoordinatorPlatformFake(output: Self.output),
            pipelineFactory: { [pipelines] in pipelines.make() },
            scheduler: CoordinatorSchedulerFake()
        )
        coordinator = DeviceProfileRuntimeCoordinator(
            profiles: profiles, hrir: hrir, equalizer: equalizer, controller: controller
        )

        // The initial directory sync publishes asynchronously; importing before
        // it lands would be overwritten by the empty scan result.
        try await wait { self.hrir.initialLibrarySyncReady }
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let imported = hrir.importPresets(
            [
                try Self.writeHRIR(to: sources.appendingPathComponent("First.wav"), gain: 1),
                try Self.writeHRIR(to: sources.appendingPathComponent("Second.wav"), gain: 0.5)
            ],
            collisionPolicy: .replace
        )
        XCTAssertEqual(imported.imported.count, 2)

        profiles.observeCurrentOutput(Self.output)
        profiles.setCurrentHRIRPresetID(try XCTUnwrap(hrir.presets.first).id)
        controller.launch(
            effectReadiness: .init(spatialReady: false, equalizerDefinition: nil),
            captureVerified: true
        )
        coordinator.launch()
        try await wait { self.state.status == .processing }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Drains main-queue work published by background activations.
    func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    func wait(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for condition") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func writeHRIR(to url: URL, gain: Float) throws -> URL {
        let channels: AVAudioChannelCount = 14
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        ))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<8 { samples[frame] = frame == 0 ? gain : 0 }
        }
        try file.write(from: buffer)
        return url
    }
}

@MainActor
private final class CoordinatorPipelineFactoryFake {
    var purposes: [AudioPipelinePurpose] = []
    var liveCount = 0

    func make() -> AudioPipelineControlling { CoordinatorLivePipelineFake(owner: self) }
}

private final class CoordinatorLivePipelineFake: AudioPipelineControlling {
    private weak var owner: CoordinatorPipelineFactoryFake?

    init(owner: CoordinatorPipelineFactoryFake) { self.owner = owner }

    func start(
        on output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        try start(
            on: output,
            purpose: muteBehavior == .unmuted ? .verification(includeOwnProcess: true) : .processing,
            verificationHandler: verificationHandler
        )
    }

    func start(
        on output: OutputDeviceDescriptor,
        purpose: AudioPipelinePurpose,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws {
        MainActor.assumeIsolated {
            owner?.purposes.append(purpose)
            owner?.liveCount += 1
        }
    }

    func stop() throws {
        MainActor.assumeIsolated {
            if let owner, owner.liveCount > 0 { owner.liveCount -= 1 }
        }
    }
}

private final class CoordinatorSchedulerFake: AudioRuntimeScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        CoordinatorCancellationFake()
    }
}

private final class CoordinatorCancellationFake: AudioRuntimeCancellation { func cancel() {} }
private final class CoordinatorPipelineFake: AudioPipelineControlling {
    func start(
        on output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws { verificationHandler(.tapReady) }
    func stop() throws {}
}

private final class CoordinatorPlatformFake: AudioPlatformClient {
    private let output: OutputDeviceDescriptor?

    init(output: OutputDeviceDescriptor? = nil) { self.output = output }

    func defaultOutputDevice() throws -> OutputDeviceDescriptor {
        guard let output else { throw AudioRuntimeError.noOutputDevice }
        return output
    }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws {}
    func stopObservingDefaultOutput() {}
    func resolveOwnProcess() throws -> AudioProcessHandle { .init(value: 1) }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle { .init(value: 1) }
    func destroyTap(_ tap: AudioTapHandle) throws {}
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle { .init(value: 1) }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {}
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func createIO(
        aggregate: PrivateAggregateHandle,
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle { .init(value: 1) }
    func startIO(_ io: AudioIOHandle) throws {}
    func stopIO(_ io: AudioIOHandle) throws {}
    func destroyIO(_ io: AudioIOHandle) throws {}
    func openAudioCapturePermissionSettings() {}
}
