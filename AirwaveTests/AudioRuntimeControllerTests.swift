import XCTest
@testable import Airwave

@MainActor
final class AudioRuntimeControllerTests: XCTestCase {
    func testLaunchWithEffectStartsOnlyUnmutedPassiveVerification() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: false)])
        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted])
        XCTAssertEqual(h.state.captureAccess, .unverified)
        XCTAssertEqual(h.player.playCount, 0)
        XCTAssertEqual(h.scheduler.scheduledCount, 0)
    }

    func testExplicitTestUsesAllProcessProbeAndOnePlayer() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.controller.requestSystemAudioAccess()

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: true)])
        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertEqual(h.state.captureAccess, .checking)
        h.scheduler.runNext()
        XCTAssertEqual(h.player.playCount, 1)
    }

    func testResigningBeforeStimulusAllowsActivationReplay() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()

        h.controller.applicationWillResignActive()
        h.controller.refreshSystemAudioAccess()
        h.scheduler.runNext() // canceled pre-deactivation stimulus
        h.scheduler.runNext() // replay after activation

        XCTAssertEqual(h.player.playCount, 1)
        XCTAssertEqual(h.state.captureAccess, .checking)
    }

    func testResigningAfterReplayCancelsOldTimeoutAndAllowsSecondReplay() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.scheduler.runNext() // first stimulus

        h.controller.applicationWillResignActive()
        h.controller.refreshSystemAudioAccess()
        h.scheduler.runNext() // canceled first timeout
        h.scheduler.runNext() // second stimulus

        XCTAssertEqual(h.player.playCount, 2)
        XCTAssertEqual(h.state.captureAccess, .checking)

        h.scheduler.runNext() // second timeout
        guard case .failed = h.state.captureAccess else {
            return XCTFail("expected second test timeout")
        }
    }

    func testCaptureVerificationTimeoutMatchesProbeBudget() {
        XCTAssertEqual(AudioRuntimeController.captureVerificationTimeout, 2.5)
        XCTAssertEqual(AudioRuntimeController.outputLossGracePeriod, 1)
    }

    func testSignalPromotesToProcessingOnlyAfterVerification() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted])
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: false), .processing])
        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted, .mutedWhenTapped])
        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testReprepareAfterVerifiedCaptureRestartsProcessingWithoutProbe() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)

        h.controller.reprepareCurrentOutput()

        XCTAssertEqual(h.pipelines.purposes, [
            .verification(includeOwnProcess: false),
            .processing,
            .processing
        ])
        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testTestAgainFromVerifiedProcessingStartsFreshExplicitProbe() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)

        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)

        h.controller.requestSystemAudioAccess()

        XCTAssertEqual(h.pipelines.purposes, [
            .processing,
            .verification(includeOwnProcess: true)
        ])
        XCTAssertEqual(h.state.captureAccess, .checking)
        XCTAssertEqual(h.state.status, .starting)
    }

    func testConflictingAppSuspendsProcessingAndReportsIssue() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        XCTAssertEqual(h.state.status, .processing)

        h.controller.tapConflictsChanged(.init(appNames: ["FineTune"]))

        XCTAssertEqual(h.pipelines.purposes, [.processing])
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertEqual(h.state.healthIssues, [.incompatibleAudioApp(appNames: ["FineTune"])])
        guard case .nativePassthrough = h.state.status else {
            return XCTFail("expected passthrough while a conflicting app runs")
        }
    }

    func testQuittingConflictingAppResumesProcessing() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        h.controller.tapConflictsChanged(.init(appNames: ["FineTune"]))

        h.controller.tapConflictsChanged(.init(appNames: []))

        XCTAssertEqual(h.pipelines.purposes, [.processing, .processing])
        XCTAssertTrue(h.state.healthIssues.isEmpty)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testConflictBeforeLaunchNeverCreatesProcessingPipeline() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.tapConflictsChanged(.init(appNames: ["FineTune"]))

        h.controller.launch(presetReady: true, captureVerified: true)

        XCTAssertEqual(h.pipelines.purposes, [])
        XCTAssertEqual(h.state.healthIssues, [.incompatibleAudioApp(appNames: ["FineTune"])])
        guard case .nativePassthrough = h.state.status else {
            return XCTFail("expected passthrough when a conflicting app is already running")
        }
    }

    func testUnchangedConflictSnapshotDoesNotInvalidate() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)

        h.controller.tapConflictsChanged(.init(appNames: []))

        XCTAssertEqual(h.pipelines.purposes, [.processing])
        XCTAssertEqual(h.state.status, .processing)
    }

    func testCaptureTestStillRunsDuringConflictThenReturnsToPassthrough() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        h.controller.tapConflictsChanged(.init(appNames: ["FineTune"]))

        h.controller.requestSystemAudioAccess()

        XCTAssertEqual(h.pipelines.purposes, [.processing, .verification(includeOwnProcess: true)])
        XCTAssertEqual(h.pipelines.muteBehaviors, [.mutedWhenTapped, .unmuted])

        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.pipelines.purposes, [.processing, .verification(includeOwnProcess: true)])
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertEqual(h.state.captureAccess, .verified)
        guard case .nativePassthrough = h.state.status else {
            return XCTFail("expected passthrough after the capture test while a conflicting app runs")
        }
    }

    func testTestAgainRepreparesSelectedEffectAfterInvalidation() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        let preparer = ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(spatialReady: true, equalizerDefinition: nil)
        )
        h.controller.setProfilePreparer(preparer)
        h.controller.launch(
            effectReadiness: AudioRuntimeEffectReadiness(spatialReady: true, equalizerDefinition: nil),
            captureVerified: true
        )

        XCTAssertEqual(preparer.prepareCount, 1)
        h.controller.requestSystemAudioAccess()

        XCTAssertEqual(preparer.prepareCount, 2)
        XCTAssertEqual(h.pipelines.purposes, [
            .processing,
            .verification(includeOwnProcess: true)
        ])

        h.pipelines.emit(.signalDetected)
        XCTAssertEqual(h.pipelines.purposes, [
            .processing,
            .verification(includeOwnProcess: true),
            .processing
        ])
        XCTAssertEqual(h.state.status, .processing)
    }

    func testSuccessfulTestAgainReturnsToProcessingAndVerified() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)

        h.controller.requestSystemAudioAccess()
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.pipelines.purposes, [
            .processing,
            .verification(includeOwnProcess: true),
            .processing
        ])
        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testPermissionDenialAfterVerifiedTestAgainNeverReturnsVerified() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)

        h.controller.requestSystemAudioAccess()
        h.pipelines.emit(.permissionDenied)

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
        XCTAssertEqual(h.state.healthIssues, [.permissionRequired])
        XCTAssertNotEqual(h.state.captureAccess, .verified)
    }

    func testStaleProcessingCallbackCannotVerifyDeniedTestAgain() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        let oldProcessingHandler = h.pipelines.handlers[0]

        h.controller.requestSystemAudioAccess()
        h.pipelines.emit(.permissionDenied)
        oldProcessingHandler(.signalDetected)

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
    }

    func testSilentExplicitTestTimesOutWithoutVerification() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.scheduler.runNext()
        h.scheduler.runNext()

        guard case .failed(let reason) = h.state.captureAccess else { return XCTFail("expected failed capture state") }
        XCTAssertTrue(reason.contains("timed out"))
        XCTAssertEqual(h.state.healthIssues, [.captureTestFailed(reason: reason)])
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertGreaterThanOrEqual(h.player.stopCount, 1)
    }

    func testPermissionFailureDoesNotClaimGenericFailure() {
        let h = Harness()
        h.pipelines.startError = .permissionDenied
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
    }

    func testPermissionIssueStaysDuringRetestAndClearsAfterSuccessfulSignal() {
        let h = Harness()
        h.pipelines.startError = .permissionDenied
        h.controller.launch(presetReady: true)

        h.controller.requestSystemAudioAccess()
        XCTAssertEqual(h.state.healthIssues, [.permissionRequired])

        h.pipelines.emit(.signalDetected)

        XCTAssertTrue(h.state.healthIssues.isEmpty)
        XCTAssertEqual(h.state.captureAccess, .verified)
    }

    func testCaptureTimeoutIssueStaysDuringRetestAndClearsAfterSuccessfulSignal() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.scheduler.runNext()
        h.scheduler.runNext()

        h.controller.requestSystemAudioAccess()
        guard case .captureTestFailed = h.state.healthIssues.first else {
            return XCTFail("capture issue should remain while the retest is in progress")
        }

        h.pipelines.emit(.signalDetected)

        XCTAssertTrue(h.state.healthIssues.isEmpty)
        XCTAssertEqual(h.state.captureAccess, .verified)
    }

    func testOpeningSystemSettingsPreservesKnownPermissionFailure() {
        let h = Harness()
        h.pipelines.startError = .permissionDenied
        h.controller.launch(presetReady: true)

        h.controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
    }

    func testTransientMissingOutputDoesNotPublishHealthIssue() {
        let h = Harness()
        h.controller.setProfilePreparer(ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
        ))
        h.controller.launch(presetReady: false)

        h.platform.emit(nil)
        h.platform.emit(output(id: 2, name: "USB"))
        h.scheduler.runNext()

        XCTAssertFalse(h.state.hasBlockingHealthIssue)
        XCTAssertEqual(h.state.currentOutput?.name, "USB")
    }

    func testSustainedMissingOutputPublishesIssueAndReconnectClearsIt() {
        let h = Harness()
        h.controller.setProfilePreparer(ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
        ))
        h.controller.launch(presetReady: false)

        h.platform.emit(nil)
        XCTAssertFalse(h.state.hasBlockingHealthIssue)
        h.scheduler.runNext()

        XCTAssertEqual(h.state.healthIssues, [.noUsableOutput])

        h.platform.emit(output(id: 2, name: "USB"))

        XCTAssertFalse(h.state.hasBlockingHealthIssue)
        XCTAssertEqual(h.state.currentOutput?.name, "USB")
    }

    func testUnsupportedOutputIssueClearsWhenSupportedOutputArrives() {
        let h = Harness()
        h.controller.setProfilePreparer(ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
        ))
        h.controller.launch(presetReady: false)

        h.platform.emit(output(id: 2, name: "Virtual", isVirtual: true))
        guard case .unsupportedOutput = h.state.healthIssues.first else {
            return XCTFail("expected unsupported-output health issue")
        }

        h.platform.emit(output(id: 3, name: "Headphones"))

        XCTAssertFalse(h.state.hasBlockingHealthIssue)
        XCTAssertEqual(h.state.currentOutput?.name, "Headphones")
    }

    func testSpatialPreparationFailurePublishesAndSuccessfulPreparationClearsIssue() {
        let h = Harness()
        let failingPreparer = ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(
                spatialReady: false,
                equalizerDefinition: nil,
                spatialError: "HRIR file is unreadable"
            )
        )
        h.controller.setProfilePreparer(failingPreparer)
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.state.healthIssues, [.spatialPresetFailed(reason: "HRIR file is unreadable")])

        let successfulPreparer = ProfilePreparerFake(
            readiness: AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
        )
        h.controller.setProfilePreparer(successfulPreparer)
        h.controller.reprepareCurrentOutput()

        XCTAssertFalse(h.state.hasBlockingHealthIssue)
    }

    func testRenderFailureIncludesOSStatusInFailureMessage() {
        let h = Harness()
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        h.pipelines.emit(.renderFailed(-50))

        guard case .audioPipelineFailed(let reason) = h.state.healthIssues.first else {
            return XCTFail("expected pipeline health issue")
        }
        XCTAssertEqual(reason, "Render system audio failed (OSStatus -50)")
        XCTAssertEqual(h.state.captureAccess, .unverified)
        XCTAssertEqual(h.state.status, .recovering(reason: "\(reason) Retrying in 1s."))
    }

    func testProcessingRenderFailureAfterVerificationSchedulesRecovery() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.pipelines.liveCount, 1)

        h.pipelines.emit(.renderFailed(-50))

        XCTAssertEqual(h.pipelines.liveCount, 0)
        guard case .recovering = h.state.status else {
            return XCTFail("expected recovery state")
        }

        h.scheduler.runNext() // canceled stability reset
        h.scheduler.runNext() // bounded retry: passive verification
        XCTAssertEqual(h.pipelines.purposes, [
            .verification(includeOwnProcess: false),
            .processing,
            .verification(includeOwnProcess: false),
            .processing
        ])
        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.pipelines.liveCount, 1)
    }

    func testReplacedVerificationCallbackCannotFailSameGenerationProcessing() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        let oldVerificationHandler = h.pipelines.handlers[0]

        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.pipelines.liveCount, 1)

        oldVerificationHandler(.renderFailed(-50))

        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertFalse(h.state.healthIssues.contains { $0.category == .pipeline })

        h.pipelines.emit(.renderFailed(-50))

        guard case .recovering = h.state.status else {
            return XCTFail("current processing failure should enter recovery")
        }
        XCTAssertEqual(h.pipelines.liveCount, 0)
    }

    func testSleepWakeRenderFailureRecoversWithoutPresetToggle() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        h.pipelines.emit(.signalDetected)
        XCTAssertEqual(h.state.status, .processing)

        h.controller.willSleep()
        XCTAssertEqual(h.pipelines.liveCount, 0)
        h.controller.didWake()
        XCTAssertEqual(h.pipelines.purposes.last, .verification(includeOwnProcess: false))
        h.pipelines.emit(.signalDetected)
        XCTAssertEqual(h.state.status, .processing)

        h.pipelines.emit(.renderFailed(-50))
        XCTAssertEqual(h.pipelines.liveCount, 0)
        h.scheduler.runAll() // canceled stability reset(s), then retry verification
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.pipelines.liveCount, 1)
    }

    func testPostWakeVerificationStartFailureSchedulesOneRetry() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        h.pipelines.emit(.signalDetected)
        h.controller.willSleep()
        h.pipelines.startError = .ioStartFailed("wake start failed")

        h.controller.didWake()

        XCTAssertEqual(h.pipelines.liveCount, 0)
        h.scheduler.runNext() // canceled stability reset
        h.scheduler.runNext() // one recovery retry
        XCTAssertEqual(h.pipelines.purposes.last, .verification(includeOwnProcess: false))
        h.pipelines.emit(.signalDetected)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testHistoricalPreSleepCallbackCannotFailCurrentPipeline() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        let oldHandler = h.pipelines.handlers[0]

        h.controller.willSleep()
        h.controller.didWake()
        oldHandler(.renderFailed(-50))

        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertFalse(h.state.healthIssues.contains { $0.category == .pipeline })
    }

    func testPermissionDenialDoesNotScheduleAutomaticRecovery() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        h.pipelines.emit(.permissionDenied)

        XCTAssertEqual(h.state.status, .needsPermission)
        XCTAssertEqual(h.pipelines.liveCount, 0)
        let purposeCount = h.pipelines.purposes.count
        h.scheduler.runAll()
        XCTAssertEqual(h.pipelines.purposes.count, purposeCount)
    }

    func testExplicitCaptureFailureDoesNotScheduleAutomaticRecovery() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()

        h.pipelines.emit(.renderFailed(-50))

        XCTAssertEqual(h.state.captureAccess, .failed(reason: "Render system audio failed (OSStatus -50)"))
        let purposeCount = h.pipelines.purposes.count
        h.scheduler.runAll()
        XCTAssertEqual(h.pipelines.purposes.count, purposeCount)
    }

    func testClearingEffectCancelsPendingRecoveryAndLeavesNativeAudio() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        h.pipelines.emit(.renderFailed(-50))
        XCTAssertEqual(h.pipelines.liveCount, 0)
        let purposeCount = h.pipelines.purposes.count

        h.controller.presetDidChange(isReady: false)
        h.scheduler.runAll()

        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertEqual(h.pipelines.purposes.count, purposeCount)
        switch h.state.status {
        case .nativePassthrough, .inactive:
            break
        default:
            XCTFail("expected native audio state")
        }
    }

    func testCleanupFailureBlocksRecoveryPipelineUntilCleanupRetry() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        h.pipelines.stopError = .cleanupFailed("busy")

        h.pipelines.emit(.renderFailed(-50))

        XCTAssertEqual(h.pipelines.liveCount, 1)
        h.pipelines.automaticEvent = nil
        h.scheduler.runNext() // canceled stability reset
        h.scheduler.runNext() // cleanup retry
        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertEqual(h.pipelines.purposes.last, .verification(includeOwnProcess: false))
    }

    func testCleanupFailurePublishesRecoveryIssueAndSuccessfulRetryClearsIt() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        h.pipelines.stopError = .cleanupFailed("busy")

        h.platform.emit(output(id: 2, name: "USB"))

        guard case .resourceRecovery = h.state.healthIssues.first else {
            return XCTFail("expected resource-recovery health issue")
        }

        h.scheduler.runNext() // canceled processing-stability timer
        h.scheduler.runNext() // cleanup retry

        XCTAssertFalse(h.state.healthIssues.contains { $0.category == .recovery })
    }

    func testFormatMismatchIncludesExpectedAndActualFormatsInFailureMessage() {
        let h = Harness()
        let expected = AudioStreamFormat.stereo(sampleRate: 44_100)
        let actual = AudioStreamFormat.stereo(sampleRate: 48_000)
        h.pipelines.startError = .formatMismatch(expected: expected, actual: actual)

        h.controller.launch(presetReady: true)

        guard case .audioPipelineFailed(let reason) = h.state.healthIssues.first else {
            return XCTFail("expected pipeline health issue")
        }
        XCTAssertEqual(reason, "Capture format mismatch (expected \(expected), actual \(actual)).")
        XCTAssertEqual(h.state.captureAccess, .unverified)
        XCTAssertEqual(h.state.status, .recovering(reason: "\(reason) Retrying in 1s."))
    }

    func testLiveSpatialUpdateKeepsTheProcessingPipeline() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        XCTAssertEqual(h.state.status, .processing)
        XCTAssertTrue(h.controller.canUpdateSpatialLive)

        XCTAssertTrue(h.controller.updateSpatialLive(isReady: true))

        XCTAssertEqual(h.pipelines.purposes, [.processing])
        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertEqual(h.state.status, .processing)
        XCTAssertEqual(h.state.captureAccess, .verified)
    }

    func testLiveSpatialUpdateStopsPipelineWhenNoEffectRemains() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        XCTAssertEqual(h.state.status, .processing)

        XCTAssertFalse(h.controller.updateSpatialLive(isReady: false))

        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertEqual(h.state.status, .inactive)
    }

    func testLiveSpatialUpdateIsRefusedWhileAConflictingAppRuns() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true, captureVerified: true)
        h.controller.tapConflictsChanged(.init(appNames: ["FineTune"]))

        XCTAssertFalse(h.controller.canUpdateSpatialLive)
        XCTAssertFalse(h.controller.updateSpatialLive(isReady: true))
        XCTAssertEqual(h.pipelines.liveCount, 0)
    }

    func testOutputChangeSleepAndTerminationReleaseResources() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        XCTAssertEqual(h.pipelines.liveCount, 1)

        h.platform.emit(output(id: 2, name: "USB"))
        XCTAssertEqual(h.pipelines.liveCount, 1)
        h.controller.willSleep()
        XCTAssertEqual(h.pipelines.liveCount, 0)
        h.controller.didWake()
        XCTAssertEqual(h.pipelines.liveCount, 1)
        h.controller.terminate()
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertGreaterThanOrEqual(h.player.stopCount, 1)
    }
}

@MainActor
private final class Harness {
    let state = AudioRuntimeState()
    let platform = PlatformFake()
    let pipelines = PipelineFactoryFake()
    let scheduler = SchedulerFake()
    let player = PlayerFake()
    private(set) lazy var controller: AudioRuntimeController = AudioRuntimeController(
        state: state,
        platform: platform,
        pipelineFactory: { [pipelines] in pipelines.make() },
        scheduler: scheduler,
        stimulusPlayer: player
    )

    init(effect: Bool = false) {
        pipelines.automaticEvent = effect ? .signalDetected : nil
    }
}

private final class PipelineFactoryFake {
    var automaticEvent: AudioCaptureVerificationEvent?
    var startError: AudioRuntimeError?
    var stopError: AudioRuntimeError?
    var purposes: [AudioPipelinePurpose] = []
    var muteBehaviors: [AudioTapMuteBehavior] = []
    var handlers: [AudioCaptureVerificationHandler] = []
    var liveCount = 0

    func make() -> PipelineFake {
        PipelineFake(owner: self)
    }

    func emit(_ event: AudioCaptureVerificationEvent) { handlers.last?(event) }
    func emit(_ event: AudioCaptureVerificationEvent, from index: Int) { handlers[index](event) }
}

private final class PipelineFake: AudioPipelineControlling {
    private weak var owner: PipelineFactoryFake?

    init(owner: PipelineFactoryFake) { self.owner = owner }

    func start(on output: OutputDeviceDescriptor, muteBehavior: AudioTapMuteBehavior, verificationHandler: @escaping AudioCaptureVerificationHandler) throws {
        try start(on: output, purpose: muteBehavior == .unmuted ? .verification(includeOwnProcess: true) : .processing, verificationHandler: verificationHandler)
    }

    func start(on output: OutputDeviceDescriptor, purpose: AudioPipelinePurpose, verificationHandler: @escaping AudioCaptureVerificationHandler) throws {
        guard let owner else { return }
        if let error = owner.startError { owner.startError = nil; throw error }
        owner.purposes.append(purpose)
        owner.muteBehaviors.append(purpose == .processing ? .mutedWhenTapped : .unmuted)
        owner.handlers.append(verificationHandler)
        owner.liveCount += 1
        if let event = owner.automaticEvent { verificationHandler(event) }
    }

    func stop() throws {
        guard let owner else { return }
        if let error = owner.stopError {
            owner.stopError = nil
            throw error
        }
        if owner.liveCount > 0 { owner.liveCount -= 1 }
    }
}

private final class PlatformFake: AudioPlatformClient {
    private var outputHandler: DefaultOutputChangeHandler?
    var current = output()

    func defaultOutputDevice() throws -> OutputDeviceDescriptor { current }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws { outputHandler = handler }
    func stopObservingDefaultOutput() { outputHandler = nil }
    func resolveOwnProcess() throws -> AudioProcessHandle { .init(value: 1) }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle { .init(value: 1) }
    func destroyTap(_ tap: AudioTapHandle) throws {}
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle { .init(value: 1) }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {}
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func createIO(aggregate: PrivateAggregateHandle, callback: @escaping AudioIOCallback, verificationHandler: @escaping AudioCaptureVerificationHandler) throws -> AudioIOHandle { .init(value: 1) }
    func startIO(_ io: AudioIOHandle) throws {}
    func stopIO(_ io: AudioIOHandle) throws {}
    func destroyIO(_ io: AudioIOHandle) throws {}
    func openAudioCapturePermissionSettings() {}

    func emit(_ output: OutputDeviceDescriptor?) { current = output ?? current; outputHandler?(output) }
}

@MainActor
private final class SchedulerFake: AudioRuntimeScheduling {
    final class Task: AudioRuntimeCancellation {
        let action: () -> Void
        var cancelled = false
        init(_ action: @escaping () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        func run() { if !cancelled { action() } }
    }

    private(set) var tasks: [Task] = []
    var scheduledCount: Int { tasks.count }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        let task = Task { action() }
        tasks.append(task)
        return task
    }
    func runNext() { guard !tasks.isEmpty else { return }; let task = tasks.removeFirst(); task.run() }
    func runAll() { while !tasks.isEmpty { runNext() } }
}

@MainActor
private final class PlayerFake: AudioProbeStimulusPlaying {
    var playCount = 0
    var stopCount = 0
    func play() throws { playCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
private final class ProfilePreparerFake: OutputEffectProfilePreparing {
    let readiness: AudioRuntimeEffectReadiness
    var prepareCount = 0

    init(readiness: AudioRuntimeEffectReadiness) {
        self.readiness = readiness
    }

    func prepare(output: OutputDeviceDescriptor, completion: @escaping (AudioRuntimeEffectReadiness) -> Void) {
        prepareCount += 1
        completion(readiness)
    }

    func cancelPreparation() {}
    func outputBecameUnsupportedOrUnavailable() {}
}

private func output(id: UInt64 = 1, name: String = "Built-in", isVirtual: Bool = false) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(id: .init(id), uid: "output-\(id)", name: name, transport: "built-in", outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: isVirtual, isAggregate: false)
}
