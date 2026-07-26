import AppKit
import Foundation

nonisolated struct AudioRuntimeEffectReadiness: Equatable, Sendable {
    let spatialReady: Bool
    let equalizerDefinition: EqualizerDefinition?
    let spatialError: String?

    init(spatialReady: Bool, equalizerDefinition: EqualizerDefinition?, spatialError: String? = nil) {
        self.spatialReady = spatialReady
        self.equalizerDefinition = equalizerDefinition
        self.spatialError = spatialError
    }

    var hasSelectedEffect: Bool { spatialReady || equalizerDefinition != nil }
}

nonisolated enum AudioRuntimeInvalidation { case spatial, equalizerTarget, output }

@MainActor
protocol OutputEffectProfilePreparing: AnyObject {
    func prepare(output: OutputDeviceDescriptor, completion: @escaping (AudioRuntimeEffectReadiness) -> Void)
    func cancelPreparation()
    func outputBecameUnsupportedOrUnavailable()
}

@MainActor
protocol AudioRuntimeScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation
}

protocol AudioRuntimeCancellation: AnyObject { func cancel() }

@MainActor
private final class DispatchRuntimeScheduler: AudioRuntimeScheduling {
    private final class Token: AudioRuntimeCancellation {
        var workItem: DispatchWorkItem?
        func cancel() { workItem?.cancel(); workItem = nil }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        let token = Token()
        let item = DispatchWorkItem {
            guard token.workItem != nil else { return }
            Task { @MainActor in action() }
        }
        token.workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }
}

@MainActor
final class AudioRuntimeController {
    typealias PipelineFactory = () -> AudioPipelineControlling
    static let captureVerificationTimeout: TimeInterval = 2.5
    static let outputLossGracePeriod: TimeInterval = 1

    static let shared: AudioRuntimeController = {
        let platform = CoreAudioPlatformClient()
        let graph = AudioEffectGraph(spatial: HRIRManager.shared, equalizer: EqualizerManager.shared.runtimeEffect)
        return AudioRuntimeController(
            state: .shared,
            platform: platform,
            pipelineFactory: { AudioPipeline(platform: platform, processor: graph) },
            scheduler: DispatchRuntimeScheduler(),
            effectGraph: graph,
            stimulusPlayer: AVAudioProbeStimulusPlayer()
        )
    }()

    private let state: AudioRuntimeState
    private let platform: AudioPlatformClient
    private let pipelineFactory: PipelineFactory
    private let scheduler: AudioRuntimeScheduling
    private let effectGraph: AudioEffectGraphControlling?
    private let stimulusPlayer: AudioProbeStimulusPlaying
    private let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    private var pipeline: AudioPipelineControlling?
    private var retryToken: AudioRuntimeCancellation?
    private var stabilityToken: AudioRuntimeCancellation?
    private var stimulusToken: AudioRuntimeCancellation?
    private var verificationTimeoutToken: AudioRuntimeCancellation?
    private var outputLossToken: AudioRuntimeCancellation?
    private var retryAttempt = 0
    private var generation = 0
    private var effectReadiness = AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
    private var captureVerified = false
    private var captureProbeRequested = false
    private var explicitCaptureTest = false
    private var replayedAfterActivation = false
    private var appIsActive = true
    private var launched = false
    private var sleeping = false
    private var terminated = false
    private weak var profilePreparer: (any OutputEffectProfilePreparing)?
    private var desiredOutput: OutputDeviceDescriptor?
    private var hasPreparedDesiredOutput = false
    private var tapConflict: TapConflictMonitor.Snapshot = .none

    init(
        state: AudioRuntimeState,
        platform: AudioPlatformClient,
        pipelineFactory: @escaping PipelineFactory,
        scheduler: AudioRuntimeScheduling,
        effectGraph: AudioEffectGraphControlling? = nil,
        stimulusPlayer: AudioProbeStimulusPlaying? = nil
    ) {
        self.state = state
        self.platform = platform
        self.pipelineFactory = pipelineFactory
        self.scheduler = scheduler
        self.effectGraph = effectGraph
        self.stimulusPlayer = stimulusPlayer ?? AVAudioProbeStimulusPlayer()
    }

    func setProfilePreparer(_ preparer: (any OutputEffectProfilePreparing)?) { profilePreparer = preparer }

    func launch(presetReady: Bool, captureVerified: Bool? = nil) {
        launch(
            effectReadiness: AudioRuntimeEffectReadiness(spatialReady: presetReady, equalizerDefinition: nil),
            captureVerified: captureVerified
        )
    }

    func launch(effectReadiness: AudioRuntimeEffectReadiness, captureVerified: Bool? = nil) {
        guard !launched else {
            self.effectReadiness = effectReadiness
            if let captureVerified { self.captureVerified = captureVerified }
            reconcile()
            return
        }
        launched = true
        self.effectReadiness = effectReadiness
        self.captureVerified = captureVerified == true
        state.setCaptureAccess(self.captureVerified ? .verified : .unverified)
        do {
            try platform.observeDefaultOutput { [weak self] output in
                MainActor.assumeIsolated { self?.defaultOutputChanged(output) }
            }
        } catch {
            handleFailure(error, output: nil)
            return
        }
        if effectReadiness.hasSelectedEffect && !self.captureVerified { captureProbeRequested = true }
        reconcile()
    }

    /// Apps that install always-on muted process taps deadlock against Airwave's
    /// own tap. Processing suspends while one runs and resumes when it quits.
    func tapConflictsChanged(_ snapshot: TapConflictMonitor.Snapshot) {
        guard snapshot != tapConflict else { return }
        tapConflict = snapshot
        state.setHealthIssue(
            snapshot.isEmpty ? nil : .incompatibleAudioApp(appNames: snapshot.appNames),
            for: .coexistence
        )
        guard launched, !sleeping, !terminated else { return }
        guard stopForInvalidation() else { return }
        reconcile()
    }

    func updateReadiness(_ effectReadiness: AudioRuntimeEffectReadiness, invalidation: AudioRuntimeInvalidation) {
        let changed = self.effectReadiness != effectReadiness
        self.effectReadiness = effectReadiness
        guard changed else { return }
        if invalidation == .equalizerTarget, let effectGraph, pipeline != nil, captureVerified {
            let result = effectGraph.updateEqualizer(definition: effectReadiness.equalizerDefinition)
            handleLiveEffectUpdate(result)
            return
        }
        guard stopForInvalidation() else { return }
        captureProbeRequested = effectReadiness.hasSelectedEffect
        reconcile()
    }

    func updateCurrentEqualizer(_ definition: EqualizerDefinition?) {
        updateReadiness(
            AudioRuntimeEffectReadiness(
                spatialReady: effectReadiness.spatialReady,
                equalizerDefinition: definition,
                spatialError: effectReadiness.spatialError
            ),
            invalidation: .equalizerTarget
        )
    }

    /// True when a spatial preset can be swapped without rebuilding the pipeline.
    var canUpdateSpatialLive: Bool {
        launched && !sleeping && !terminated
            && pipeline != nil && captureVerified
            && state.status.isProcessing && tapConflict.isEmpty
    }

    /// Applies a spatial readiness change without stopping the tap. The renderer
    /// state was already published to the render thread, which crossfades to it.
    /// Falls back to the full restart path when the pipeline is not live.
    @discardableResult
    func updateSpatialLive(isReady: Bool) -> Bool {
        let readiness = AudioRuntimeEffectReadiness(
            spatialReady: isReady,
            equalizerDefinition: effectReadiness.equalizerDefinition
        )
        guard canUpdateSpatialLive, readiness.hasSelectedEffect else {
            updateReadiness(readiness, invalidation: .spatial)
            return false
        }
        effectReadiness = readiness
        state.setHealthIssue(nil, for: .spatial)
        state.setHealthIssue(nil, for: .pipeline)
        state.publish(
            .processing,
            output: state.currentOutput,
            warning: state.warningMessage,
            captureAccess: .verified
        )
        scheduleStabilityReset(for: generation)
        return true
    }

    func reprepareCurrentOutput() {
        guard launched, !sleeping, !terminated, stopForInvalidation() else { return }
        hasPreparedDesiredOutput = false
        // Rebuilding the effect graph does not revoke capture capability. Keep
        // verified state so HRIR swaps restart processing directly instead of
        // waiting for another unrelated passive signal.
        captureProbeRequested = explicitCaptureTest || (effectReadiness.hasSelectedEffect && !captureVerified)
        reconcile()
    }

    func presetDidChange(isReady: Bool) {
        updateReadiness(
            AudioRuntimeEffectReadiness(
                spatialReady: isReady,
                equalizerDefinition: effectReadiness.equalizerDefinition
            ),
            invalidation: .spatial
        )
    }

    func presetActivationFailed(_ message: String) {
        effectReadiness = AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil, spatialError: message)
        guard stopForInvalidation() else { return }
        state.setHealthIssue(.spatialPresetFailed(reason: message), for: .spatial)
        state.publish(.nativePassthrough(reason: message), output: state.currentOutput)
    }

    func retryNow() {
        retryAttempt = 0
        retryToken?.cancel()
        retryToken = nil
        captureProbeRequested = explicitCaptureTest || effectReadiness.hasSelectedEffect
        if captureProbeRequested { state.setCaptureAccess(.checking) }
        reconcile()
    }

    func requestSystemAudioAccess() {
        guard launched, !sleeping, !terminated, !explicitCaptureTest else { return }
        guard stopForInvalidation() else { return }
        // Explicit tests always start from a fresh capture verification. Do
        // not let a previous processing session bypass the probe.
        explicitCaptureTest = true
        captureProbeRequested = true
        captureVerified = false
        replayedAfterActivation = false
        state.setCaptureAccess(.checking)
        reconcile()
    }

    /// Activation only retries pending public behavioral verification. No status API is queried.
    func refreshSystemAudioAccess() {
        appIsActive = true
        guard explicitCaptureTest, pipeline != nil, !replayedAfterActivation else { return }
        replayedAfterActivation = true
        scheduleStimulus(for: generation)
    }

    func applicationWillResignActive() {
        appIsActive = false
        replayedAfterActivation = false
        stimulusToken?.cancel()
        stimulusToken = nil
        verificationTimeoutToken?.cancel()
        verificationTimeoutToken = nil
        stimulusPlayer.stop()
    }

    func openSystemAudioRecordingSettings() {
        platform.openAudioCapturePermissionSettings()
    }

    func willSleep() {
        sleeping = true
        outputLossToken?.cancel()
        outputLossToken = nil
        guard stopForInvalidation() else { return }
        explicitCaptureTest = false
        captureProbeRequested = false
        state.publish(.nativePassthrough(reason: "Sleeping; native audio remains active."), captureAccess: .unverified)
    }

    func didWake() {
        guard !terminated else { return }
        sleeping = false
        captureVerified = false
        captureProbeRequested = effectReadiness.hasSelectedEffect
        state.setCaptureAccess(.unverified)
        reconcile()
    }

    func terminate() {
        terminated = true
        outputLossToken?.cancel()
        outputLossToken = nil
        stimulusPlayer.stop()
        platform.stopObservingDefaultOutput()
        _ = stopForInvalidation()
        state.publish(.unavailable("Airwave stopped"), captureAccess: .unverified)
    }

    private func defaultOutputChanged(_ output: OutputDeviceDescriptor?) {
        guard launched, !sleeping, !terminated else { return }
        outputLossToken?.cancel()
        outputLossToken = nil
        if let output, output == state.currentOutput, pipeline != nil, state.status == .processing { return }
        desiredOutput = output
        hasPreparedDesiredOutput = false
        guard stopForInvalidation() else { return }
        captureVerified = false
        captureProbeRequested = explicitCaptureTest || effectReadiness.hasSelectedEffect
        state.setCaptureAccess(.unverified)
        guard let output else {
            profilePreparer?.outputBecameUnsupportedOrUnavailable()
            state.publish(.recovering(reason: "Waiting for the new audio output…"), output: nil)
            let lossGeneration = generation
            outputLossToken = scheduler.schedule(after: Self.outputLossGracePeriod) { [weak self] in
                guard let self, self.generation == lossGeneration,
                      self.desiredOutput == nil, !self.sleeping, !self.terminated else { return }
                self.outputLossToken = nil
                self.state.setHealthIssue(.noUsableOutput, for: .output)
                self.state.publish(
                    .nativePassthrough(reason: "No usable output is currently available."),
                    output: nil,
                    captureAccess: .unverified
                )
            }
            return
        }
        state.setHealthIssue(nil, for: .output)
        transition(to: output)
    }

    private func reconcile() {
        guard launched, !sleeping, !terminated else { return }
        if let desiredOutput, hasPreparedDesiredOutput {
            guard effectReadiness.hasSelectedEffect || captureProbeRequested else {
                publishInactive(output: desiredOutput)
                return
            }
            start(on: desiredOutput)
            return
        }
        guard profilePreparer != nil || effectReadiness.hasSelectedEffect || captureProbeRequested else {
            if let output = state.currentOutput { publishInactive(output: output) }
            else { state.publish(.inactive) }
            return
        }
        do { transition(to: try platform.defaultOutputDevice()) }
        catch { handleFailure(error, output: nil) }
    }

    private func transition(to output: OutputDeviceDescriptor) {
        guard validate(output) else { return }
        desiredOutput = output
        hasPreparedDesiredOutput = false
        guard let profilePreparer else {
            hasPreparedDesiredOutput = true
            start(on: output)
            return
        }
        let preparationGeneration = generation
        state.publish(.starting, output: output)
        profilePreparer.prepare(output: output) { [weak self] readiness in
            guard let self, preparationGeneration == self.generation,
                  self.desiredOutput?.uid == output.uid, !self.sleeping, !self.terminated else { return }
            self.effectReadiness = readiness
            self.state.setHealthIssue(
                readiness.spatialError.map(RuntimeHealthIssue.spatialPresetFailed(reason:)),
                for: .spatial
            )
            self.hasPreparedDesiredOutput = true
            if readiness.hasSelectedEffect { self.captureProbeRequested = !self.captureVerified }
            guard readiness.hasSelectedEffect || self.captureProbeRequested else {
                self.publishInactive(output: output)
                return
            }
            self.start(on: output)
        }
    }

    private func publishInactive(output: OutputDeviceDescriptor) {
        if let error = effectReadiness.spatialError { state.publish(.nativePassthrough(reason: error), output: output) }
        else {
            state.setHealthIssue(nil, for: .spatial)
            state.publish(.inactive, output: output)
        }
    }

    private func start(on output: OutputDeviceDescriptor) {
        guard validate(output) else { return }
        let purpose: AudioPipelinePurpose = captureProbeRequested && !captureVerified
            ? .verification(includeOwnProcess: explicitCaptureTest)
            : .processing
        if purpose == .processing, !tapConflict.isEmpty {
            let names = tapConflict.appNames.joined(separator: ", ")
            state.publish(
                .nativePassthrough(reason: "\(names) is managing per-app audio. Airwave paused processing to keep sound working."),
                output: output
            )
            return
        }
        let preparation: AudioEffectPreparationResult?
        if let effectGraph {
            let result = effectGraph.prepare(for: output, equalizerDefinition: effectReadiness.equalizerDefinition)
            publishEqualizerIssue(result.equalizerWarning)
            guard purpose != .processing || !result.noEffectCanRun else {
                state.publish(.nativePassthrough(reason: result.equalizerWarning?.errorDescription ?? "No compatible audio effect is available for this output."), output: output)
                return
            }
            preparation = result
        } else { preparation = nil }

        let currentGeneration = generation
        try? pipeline?.stop()
        let candidate = pipelineFactory()
        let candidateIdentity = ObjectIdentifier(candidate)
        pipeline = candidate
        let captureAccess: AudioRuntimeState.CaptureAccess?
        switch purpose {
        case .verification:
            captureAccess = explicitCaptureTest ? .checking : .unverified
        case .processing:
            captureAccess = nil
        }
        state.publish(.starting, output: output, warning: preparation?.equalizerWarning?.errorDescription, captureAccess: captureAccess)
        do {
            try candidate.start(on: output, purpose: purpose) { [weak self] event in
                guard let self else { return }
                let work = { @MainActor in
                    self.handleCaptureVerification(
                        event,
                        purpose: purpose,
                        generation: currentGeneration,
                        pipelineIdentity: candidateIdentity,
                        output: output,
                        warning: preparation?.equalizerWarning?.errorDescription
                    )
                }
                if Thread.isMainThread { MainActor.assumeIsolated { work() } }
                else { DispatchQueue.main.async(execute: work) }
            }
            guard currentGeneration == generation, !sleeping, !terminated else { try? candidate.stop(); return }
            if case .verification = purpose {
                guard !captureVerified else { return }
                state.setCaptureAccess(explicitCaptureTest ? .checking : .unverified)
                if explicitCaptureTest { scheduleStimulus(for: currentGeneration) }
            } else {
                clearCaptureAndPipelineIssuesAfterSuccess()
                state.publish(.processing, output: output, warning: preparation?.equalizerWarning?.errorDescription, captureAccess: .verified)
                scheduleStabilityReset(for: currentGeneration)
            }
        } catch {
            pipeline = nil
            try? candidate.stop()
            handleFailure(
                error,
                output: output,
                shouldScheduleRetry: !explicitCaptureTest && effectReadiness.hasSelectedEffect
            )
        }
    }

    private func scheduleStimulus(for currentGeneration: Int) {
        stimulusToken?.cancel()
        stimulusToken = scheduler.schedule(after: 0.1) { [weak self] in
            guard let self, currentGeneration == self.generation, self.explicitCaptureTest, !self.sleeping, self.appIsActive else { return }
            self.stimulusToken = nil
            do { try self.stimulusPlayer.play() }
            catch { self.handleFailure(error, output: self.state.currentOutput) }
            self.scheduleVerificationTimeout(for: currentGeneration)
        }
    }

    private func scheduleVerificationTimeout(for currentGeneration: Int) {
        verificationTimeoutToken?.cancel()
        verificationTimeoutToken = scheduler.schedule(after: Self.captureVerificationTimeout) { [weak self] in
            guard let self, currentGeneration == self.generation, !self.captureVerified else { return }
            guard self.appIsActive else { return }
            self.stimulusPlayer.stop()
            self.captureProbeRequested = false
            self.explicitCaptureTest = false
            _ = self.stopForInvalidation()
            self.state.setHealthIssue(
                .captureTestFailed(reason: "Capture test timed out. Retry the test sound."),
                for: .capture
            )
            self.state.publish(.nativePassthrough(reason: "Capture test timed out. Retry the test sound."), output: self.state.currentOutput, captureAccess: .failed(reason: "Capture test timed out. Retry the test sound."))
        }
    }

    private func handleCaptureVerification(
        _ event: AudioCaptureVerificationEvent,
        purpose: AudioPipelinePurpose,
        generation eventGeneration: Int,
        pipelineIdentity eventPipelineIdentity: ObjectIdentifier,
        output: OutputDeviceDescriptor,
        warning: String?
    ) {
        guard eventGeneration == generation,
              let currentPipeline = pipeline,
              ObjectIdentifier(currentPipeline) == eventPipelineIdentity else { return }
        switch event {
        case .signalDetected:
            guard case .verification = purpose, !captureVerified else { return }
            captureVerified = true
            captureProbeRequested = false
            explicitCaptureTest = false
            stimulusToken?.cancel(); stimulusToken = nil
            verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
            stimulusPlayer.stop()
            guard (try? pipeline?.stop()) != nil else { handleFailure(AudioRuntimeError.cleanupFailed("Stop verification pipeline"), output: output); return }
            pipeline = nil
            clearCaptureAndPipelineIssuesAfterSuccess()
            state.setCaptureAccess(.verified)
            if effectReadiness.hasSelectedEffect { start(on: output) }
            else { state.publish(.inactive, output: output, captureAccess: .verified) }
        case .permissionDenied:
            handleFailure(AudioRuntimeError.permissionDenied, output: output)
        case .renderFailed(let status):
            handleFailure(
                AudioRuntimeError.ioStartFailed("Render system audio failed (OSStatus \(status))"),
                output: output,
                shouldScheduleRetry: !explicitCaptureTest && effectReadiness.hasSelectedEffect
            )
        }
    }

    private func handleFailure(
        _ error: Error,
        output: OutputDeviceDescriptor?,
        shouldScheduleRetry: Bool = false
    ) {
        let wasExplicitCaptureTest = explicitCaptureTest
        stimulusPlayer.stop()
        verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
        stimulusToken?.cancel(); stimulusToken = nil
        let didStop = stopForInvalidation()
        if case AudioRuntimeError.permissionDenied = error {
            captureVerified = false
            captureProbeRequested = false
            explicitCaptureTest = false
            state.setHealthIssue(.permissionRequired, for: .permission)
            state.setHealthIssue(nil, for: .capture)
            state.setHealthIssue(nil, for: .pipeline)
            state.publish(.needsPermission, output: output, captureAccess: .permissionRequired)
            return
        }
        if case AudioRuntimeError.unsupportedOutput = error {
            let reason = output?.unsupportedProfileReason ?? "Unsupported output. Change output in macOS Settings."
            state.setHealthIssue(.unsupportedOutput(reason: reason), for: .output)
            state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .unverified)
            return
        }
        let reason = failureMessage(error)
        captureVerified = false
        captureProbeRequested = false
        explicitCaptureTest = false
        if error as? AudioRuntimeError == .noOutputDevice || error as? AudioRuntimeError == .deviceLost {
            state.setHealthIssue(.noUsableOutput, for: .output)
            state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .unverified)
        } else if wasExplicitCaptureTest {
            state.setHealthIssue(.captureTestFailed(reason: reason), for: .capture)
            state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .failed(reason: reason))
        } else {
            state.setHealthIssue(.audioPipelineFailed(reason: reason), for: .pipeline)
            state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .unverified)
            if shouldScheduleRetry && didStop {
                scheduleRetry(reason: reason, output: output)
            }
        }
    }

    private func validate(_ output: OutputDeviceDescriptor) -> Bool {
        guard let reason = output.unsupportedProfileReason else {
            state.setHealthIssue(nil, for: .output)
            return true
        }
        state.setHealthIssue(.unsupportedOutput(reason: reason), for: .output)
        state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .unverified)
        return false
    }

    private func stopForInvalidation() -> Bool {
        generation += 1
        verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
        stimulusToken?.cancel(); stimulusToken = nil
        stimulusPlayer.stop()
        profilePreparer?.cancelPreparation()
        // Profile cancellation deactivates HRIR state. Any subsequent start
        // must run profile preparation again before creating a processing tap.
        hasPreparedDesiredOutput = false
        retryToken?.cancel(); retryToken = nil
        stabilityToken?.cancel(); stabilityToken = nil
        guard let pipeline else { return true }
        do {
            try pipeline.stop()
            self.pipeline = nil
            state.setHealthIssue(nil, for: .recovery)
            return true
        }
        catch { scheduleCleanupRetry(error); return false }
    }

    private func scheduleRetry(reason: String, output: OutputDeviceDescriptor?) {
        guard retryToken == nil, effectReadiness.hasSelectedEffect, !sleeping, !terminated else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let retryGeneration = generation
        state.publish(.recovering(reason: "\(reason) Retrying in \(Int(delay))s."), output: output)
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == retryGeneration else { return }
            self.retryToken = nil; self.captureProbeRequested = true; self.reconcile()
        }
    }

    private func scheduleCleanupRetry(_ error: Error) {
        guard retryToken == nil else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let retryGeneration = generation
        let reason = "Releasing audio resources. Retrying in \(Int(delay))s."
        state.setHealthIssue(.resourceRecovery(reason: reason), for: .recovery)
        state.publish(.recovering(reason: reason))
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == retryGeneration else { return }
            self.retryToken = nil
            guard self.stopForInvalidation() else { return }
            if self.effectReadiness.hasSelectedEffect && !self.explicitCaptureTest {
                self.captureProbeRequested = true
            }
            self.reconcile()
        }
    }

    private func scheduleStabilityReset(for currentGeneration: Int) {
        stabilityToken?.cancel()
        stabilityToken = scheduler.schedule(after: 30) { [weak self] in
            guard let self, self.generation == currentGeneration, self.state.status.isProcessing else { return }
            self.retryAttempt = 0; self.stabilityToken = nil
        }
    }

    private func handleLiveEffectUpdate(_ result: AudioEffectPreparationResult) {
        publishEqualizerIssue(result.equalizerWarning)
        if result.noEffectCanRun, !effectReadiness.spatialReady {
            state.publish(.nativePassthrough(reason: result.equalizerWarning?.errorDescription ?? "No compatible audio effect is available for this output."), output: state.currentOutput)
            return
        }
        state.setHealthIssue(nil, for: .pipeline)
        state.publish(.processing, output: state.currentOutput, warning: result.equalizerWarning?.errorDescription, captureAccess: .verified)
        scheduleStabilityReset(for: generation)
    }

    private func failureMessage(_ error: Error) -> String {
        switch error {
        case AudioRuntimeError.noOutputDevice, AudioRuntimeError.deviceLost:
            return "No usable output is currently available."
        case let error as AudioRuntimeError:
            switch error {
            case .tapCreationFailed(let reason), .aggregateCreationFailed(let reason), .ioCreationFailed(let reason), .ioStartFailed(let reason):
                return reason
            case .formatMismatch(let expected, let actual):
                return "Capture format mismatch (expected \(expected), actual \(actual))."
            default: return "Audio capture test failed safely."
            }
        default: return "Audio capture test failed safely."
        }
    }

    private func publishEqualizerIssue(_ warning: AudioEffectWarning?) {
        state.setHealthIssue(
            warning.map { .equalizerFailed(reason: $0.errorDescription ?? $0.reason) },
            for: .equalizer
        )
    }

    private func clearCaptureAndPipelineIssuesAfterSuccess() {
        state.setHealthIssue(nil, for: .permission)
        state.setHealthIssue(nil, for: .capture)
        state.setHealthIssue(nil, for: .pipeline)
        state.setHealthIssue(nil, for: .recovery)
    }
}

extension AudioRuntimeController: AudioRuntimeUserActions {}
