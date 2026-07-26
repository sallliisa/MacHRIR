import XCTest
@testable import Airwave

@MainActor
final class ProductSurfaceTests: XCTestCase {
    func testLoginItemLaunchNeverPresentsWindow() {
        for showsMenuBar in [false, true] {
            for setupIsComplete in [false, true] {
                XCTAssertEqual(
                    LaunchWindowPolicy.action(
                        for: .loginItemLaunch,
                        setupIsComplete: setupIsComplete,
                        showsMenuBar: showsMenuBar
                    ),
                    .none
                )
            }
        }
    }

    func testExplicitColdLaunchPresentsSetupOrSettingsRegardlessOfMenuBar() {
        for showsMenuBar in [false, true] {
            XCTAssertEqual(
                LaunchWindowPolicy.action(
                    for: .userColdOpen,
                    setupIsComplete: false,
                    showsMenuBar: showsMenuBar
                ),
                .setup
            )
            XCTAssertEqual(
                LaunchWindowPolicy.action(
                    for: .userColdOpen,
                    setupIsComplete: true,
                    showsMenuBar: showsMenuBar
                ),
                .settings
            )
        }
    }

    func testSubsequentOpenPresentsSetupOrSettingsRegardlessOfMenuBar() {
        for showsMenuBar in [false, true] {
            XCTAssertEqual(
                LaunchWindowPolicy.action(
                    for: .userReopen,
                    setupIsComplete: false,
                    showsMenuBar: showsMenuBar
                ),
                .setup
            )
            XCTAssertEqual(
                LaunchWindowPolicy.action(
                    for: .userReopen,
                    setupIsComplete: true,
                    showsMenuBar: showsMenuBar
                ),
                .settings
            )
        }
    }

    func testAppleEventDescriptorRoutingUsesMarkerAndTrustedSenderPrecedence() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertEqual(LaunchWindowAppleEventClassifier.event(for: event), .loginItemLaunch)
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: applicationEvent(id: kAEOpenApplication),
                senderBundleIdentifier: LaunchWindowAppleEventClassifier.loginWindowBundleIdentifier
            ),
            .loginItemLaunch
        )
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: applicationEvent(id: kAEReopenApplication),
                senderBundleIdentifier: LaunchWindowAppleEventClassifier.loginWindowBundleIdentifier
            ),
            .loginItemLaunch
        )
        for sender in [String?("com.apple.finder"), "com.apple.dock", "com.apple.Spotlight", nil] {
            XCTAssertEqual(
                LaunchWindowAppleEventClassifier.event(
                    for: applicationEvent(id: kAEOpenApplication),
                    senderBundleIdentifier: sender
                ),
                .userColdOpen
            )
        }
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: applicationEvent(id: kAEReopenApplication),
                senderBundleIdentifier: "com.apple.finder"
            ),
            .userReopen
        )
    }

    func testAppDelegateResolvesSenderOnceBeforeClassifying() {
        let router = AppleEventRouterFake()
        let resolver = AppleEventSenderResolverFake(bundleIdentifier: LaunchWindowAppleEventClassifier.loginWindowBundleIdentifier)
        let delegate = AppDelegate(appleEventRouter: router, senderResolver: resolver)
        let event = applicationEvent(id: kAEOpenApplication)

        delegate.handleOpenApplicationEvent(event, withReplyEvent: event)

        XCTAssertEqual(resolver.resolutionCount, 1)
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: event,
                senderBundleIdentifier: resolver.bundleIdentifier
            ),
            .loginItemLaunch
        )
    }

    func testSystemSenderResolverReturnsNilWhenSenderPIDIsMissing() {
        XCTAssertNil(SystemAppleEventSenderResolver().bundleIdentifier(for: applicationEvent(id: kAEOpenApplication)))
    }

    func testUnpreparedTerminationIsCancelled() {
        let application = ApplicationLifecycleApplicationFake()
        let coordinator = ApplicationLifecycleCoordinator(application: application, observeWindows: false)

        XCTAssertEqual(coordinator.terminationReply(), .terminateCancel)
        XCTAssertEqual(application.terminateCallCount, 0)
    }

    func testUpdateRelaunchTerminationIsAllowedWithoutRequestingTermination() {
        let application = ApplicationLifecycleApplicationFake()
        let coordinator = ApplicationLifecycleCoordinator(application: application, observeWindows: false)

        coordinator.beginUpdateRelaunchTermination()

        XCTAssertEqual(coordinator.terminationReply(), .terminateNow)
        XCTAssertEqual(application.terminateCallCount, 0)
    }

    func testUpdateRelaunchTerminationAuthorizationIsOneShot() {
        let application = ApplicationLifecycleApplicationFake()
        let coordinator = ApplicationLifecycleCoordinator(application: application, observeWindows: false)

        coordinator.beginUpdateRelaunchTermination()

        XCTAssertEqual(coordinator.terminationReply(), .terminateNow)
        XCTAssertEqual(coordinator.terminationReply(), .terminateCancel)
    }

    func testExplicitQuitStillTerminatesOnceAndAllowsFollowingReply() {
        let application = ApplicationLifecycleApplicationFake()
        let coordinator = ApplicationLifecycleCoordinator(application: application, observeWindows: false)

        coordinator.requestExplicitQuit()

        XCTAssertEqual(application.terminateCallCount, 1)
        XCTAssertEqual(coordinator.terminationReply(), .terminateNow)
    }

    func testLoginWindowEventsNeverPresentAndUserReopenPresentsOnce() {
        for event in [
            applicationEvent(id: kAEOpenApplication),
            applicationEvent(id: kAEReopenApplication)
        ] {
            let intent = LaunchWindowAppleEventClassifier.event(
                for: event,
                senderBundleIdentifier: LaunchWindowAppleEventClassifier.loginWindowBundleIdentifier
            )
            XCTAssertEqual(intent, .loginItemLaunch)
            XCTAssertEqual(
                LaunchWindowPolicy.action(for: intent!, setupIsComplete: true, showsMenuBar: true),
                .none
            )
        }
        let explicitReopen = LaunchWindowAppleEventClassifier.event(
            for: applicationEvent(id: kAEReopenApplication),
            senderBundleIdentifier: "com.apple.finder"
        )
        XCTAssertEqual(explicitReopen, .userReopen)
        XCTAssertEqual(
            LaunchWindowPolicy.action(for: explicitReopen!, setupIsComplete: true, showsMenuBar: true),
            .settings
        )
    }

    func testAppleEventDescriptorWithoutMarkerRemainsColdForNonLoginSender() {
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: applicationEvent(id: kAEOpenApplication),
                senderBundleIdentifier: "com.apple.Terminal"
            ),
            .userColdOpen
        )
        XCTAssertEqual(
            LaunchWindowAppleEventClassifier.event(
                for: applicationEvent(id: kAEReopenApplication),
                senderBundleIdentifier: nil
            ),
            .userReopen
        )
    }

    func testAppleEventRegistrationUsesOpenAndReopenHandlers() {
        let router = AppleEventRouterFake()
        let delegate = AppDelegate(appleEventRouter: router)

        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))

        XCTAssertEqual(router.registrations.map(\.eventID), [
            AEEventID(kAEOpenApplication),
            AEEventID(kAEReopenApplication)
        ])
        XCTAssertEqual(router.registrations.map(\.eventClass), [AEEventClass(kCoreEventClass), AEEventClass(kCoreEventClass)])
        XCTAssertEqual(router.registrations.map(\.selector), [
            #selector(AppDelegate.handleOpenApplicationEvent(_:withReplyEvent:)),
            #selector(AppDelegate.handleReopenApplicationEvent(_:withReplyEvent:))
        ])
    }

    func testLoginItemIsSilentAndQueuedReopenPresentsAfterReadiness() {
        var coordinator = LaunchWindowCoordinator()
        let loginEvent = applicationEvent(id: kAEOpenApplication, loginItem: true)
        let reopenEvent = applicationEvent(id: kAEReopenApplication)

        XCTAssertEqual(
            coordinator.action(
                for: .loginItemLaunch,
                setupIsComplete: true,
                showsMenuBar: true,
                isReady: false,
                deliveryToken: AppleEventDeliveryToken(event: loginEvent)
            ),
            .none
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userReopen,
                setupIsComplete: true,
                showsMenuBar: true,
                isReady: false,
                deliveryToken: AppleEventDeliveryToken(event: reopenEvent)
            ),
            .none
        )
        XCTAssertEqual(
            coordinator.drainPendingActions(setupIsComplete: true, showsMenuBar: true),
            [
                LaunchWindowPendingAction(event: .loginItemLaunch, action: .none),
                LaunchWindowPendingAction(event: .userReopen, action: .settings)
            ]
        )
    }

    func testColdOpenDeduplicatesSameDeliveryButAllowsLaterReopens() {
        var coordinator = LaunchWindowCoordinator()
        let coldOpen = applicationEvent(id: kAEOpenApplication)
        let reopen = applicationEvent(id: kAEReopenApplication)
        let laterReopen = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: nil,
            returnID: 7,
            transactionID: 8
        )

        XCTAssertEqual(
            coordinator.action(
                for: .userColdOpen,
                setupIsComplete: false,
                showsMenuBar: false,
                deliveryToken: AppleEventDeliveryToken(event: coldOpen)
            ),
            .setup
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userColdOpen,
                setupIsComplete: false,
                showsMenuBar: false,
                deliveryToken: AppleEventDeliveryToken(event: coldOpen)
            ),
            .none
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userReopen,
                setupIsComplete: true,
                showsMenuBar: true,
                deliveryToken: AppleEventDeliveryToken(event: reopen)
            ),
            .settings
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userReopen,
                setupIsComplete: true,
                showsMenuBar: true,
                deliveryToken: AppleEventDeliveryToken(event: reopen)
            ),
            .none
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userReopen,
                setupIsComplete: false,
                showsMenuBar: false,
                deliveryToken: AppleEventDeliveryToken(event: laterReopen)
            ),
            .setup
        )
        XCTAssertEqual(
            coordinator.action(
                for: .userReopen,
                setupIsComplete: true,
                showsMenuBar: true,
                deliveryToken: AppleEventDeliveryToken(event: laterReopen)
            ),
            .none
        )
    }

    func testUnknownAppleEventsProduceNoIntent() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertNil(LaunchWindowAppleEventClassifier.event(for: event))
    }

    func testSettingsSurfaceIncludesResourceLinksPickerLabelsIconsAndHitTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let style = try String(contentsOf: root.appendingPathComponent("Airwave/AirwaveStyle.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Airwave/SettingsView.swift"), encoding: .utf8)
        let equalizer = try String(contentsOf: root.appendingPathComponent("Airwave/EqualizerSettingsView.swift"), encoding: .utf8)
        // Both pickers share one library component; its chrome lives there.
        let library = try String(contentsOf: root.appendingPathComponent("Airwave/PresetLibraryView.swift"), encoding: .utf8)

        XCTAssertTrue(library.contains("Get more HRIRs…"))
        XCTAssertTrue(library.contains("Get more equalizer presets…"))
        XCTAssertTrue(style.contains("https://airtable.com/embed/appac4r1cu9UpBNAN/shrpUAbtyZxhDDMjg/tblopH2GznvFipWjq/viwnouWPGDuYEd8Go"))
        XCTAssertTrue(style.contains("https://autoeq.app/"))
        XCTAssertTrue(library.contains("Button(\"Manage…\")"))
        XCTAssertFalse(library.contains("Button(\"Show in Finder\")"))
        XCTAssertFalse(style.contains("Button(\"Show in Finder\")"))
        XCTAssertFalse(equalizer.contains("Button(\"Show in Finder\")"))
        XCTAssertTrue(library.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(library.contains(".foregroundStyle(.tint)"))
        XCTAssertTrue(equalizer.contains(".buttonStyle(.plain)"))

        let rowsSource = try XCTUnwrap(equalizer.range(of: "private var rows"))
        XCTAssertFalse(String(equalizer[rowsSource.lowerBound...]).contains("title: \"Equalizer Presets\""))

        for icon in ["slider.horizontal.3", "headphones", "sparkles", "gearshape"] {
            XCTAssertTrue(settings.contains("systemImage: \"\(icon)\""))
        }
        XCTAssertTrue(settings.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(settings.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(settings.contains("isReady: onboarding.runtime.isSetupHealthy"))
    }

    func testSettingsPageUsesOneUnifiedTransition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Airwave/SettingsView.swift"),
            encoding: .utf8
        )

        let settingsStart = try XCTUnwrap(source.range(of: "struct SettingsView: View"))
        let generalPageStart = try XCTUnwrap(
            source.range(of: "private var generalPage", range: settingsStart.lowerBound..<source.endIndex)
        )
        let pageSwitchingSource = String(source[settingsStart.lowerBound..<generalPageStart.lowerBound])
        XCTAssertTrue(pageSwitchingSource.contains(".id(page.wrappedValue)"))
        XCTAssertEqual(
            pageSwitchingSource.components(separatedBy: ".transition(pageRevealTransition)").count - 1,
            1
        )

        let pageContentStart = try XCTUnwrap(pageSwitchingSource.range(of: "private var settingsPageContent"))
        let pageContentSource = pageSwitchingSource[pageContentStart.lowerBound...]
        XCTAssertFalse(pageContentSource.contains(".transition("))
    }

    func testRegisteredDevicesUsesSelectableRowsAndPickerFooterActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Airwave/DeviceManagementView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var selectedDeviceUID: String?"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(selectedDeviceUID == row.id ? .isSelected : [])"))
        XCTAssertTrue(source.contains("private var actionFooter: some View"))
        XCTAssertTrue(source.contains(".disabled(selectedRow?.canReset != true)"))
        XCTAssertTrue(source.contains(".disabled(selectedRow?.canForget != true)"))

        let row = try XCTUnwrap(source.range(of: "private func deviceRow"))
        let footer = try XCTUnwrap(source.range(of: "private var actionFooter"))
        let rowSource = String(source[row.lowerBound..<footer.lowerBound])
        XCTAssertFalse(rowSource.contains("Button(\"Reset Profile\")"))
        XCTAssertFalse(rowSource.contains("Button(\"Forget Device\")"))
        XCTAssertFalse(rowSource.contains("Image(systemName: \"checkmark\")"))
        XCTAssertTrue(source[source.startIndex..<row.lowerBound].contains("Divider()"))
    }

    func testPickerActionsHaveNoSuccessIndicatorsButRetainFailureFeedback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let device = try String(
            contentsOf: root.appendingPathComponent("Airwave/DeviceManagementView.swift"),
            encoding: .utf8
        )
        let hrir = try String(
            contentsOf: root.appendingPathComponent("Airwave/AirwaveStyle.swift"),
            encoding: .utf8
        )
        let equalizer = try String(
            contentsOf: root.appendingPathComponent("Airwave/EqualizerSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(device.contains("DeviceManagementResult"))
        XCTAssertFalse(device.contains("coordinator.result"))
        XCTAssertFalse(device.contains("checkmark.circle.fill"))
        let library = try String(
            contentsOf: root.appendingPathComponent("Airwave/PresetLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(hrir.contains("isSuccess"))
        XCTAssertFalse(equalizer.contains("isSuccess"))
        XCTAssertFalse(library.contains("isSuccess"))
        XCTAssertTrue(library.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(library.contains("confirmationDialog("))
    }

    func testOnboardingHasOneCaptureCardAndNoSplitHealthCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        XCTAssertEqual(source.components(separatedBy: "title: \"System Audio Capture\"").count - 1, 1)
        XCTAssertTrue(source.contains("Test System Audio Capture"))
        XCTAssertFalse(source.contains(["Audio", "Tap Health"].joined(separator: " ")))
        XCTAssertFalse(source.contains(["macOS", "Permission"].joined(separator: " ")))
    }

    func testVerifiedOnboardingControlIsEnabledTestAgainButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)
        let verifiedStart = try XCTUnwrap(source.range(of: "case .verified:"))
        let failureStart = try XCTUnwrap(source.range(of: "case .permissionRequired, .failed:", range: verifiedStart.upperBound..<source.endIndex))
        let verifiedControls = String(source[verifiedStart.lowerBound..<failureStart.lowerBound])

        XCTAssertTrue(verifiedControls.contains("Button(\"Test Again\") { viewModel.requestPermission() }"))
        XCTAssertFalse(verifiedControls.contains(".disabled(true)"))
    }

    func testOnboardingHRIRDescriptionCanWrap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains(".frame(height: 260, alignment: .top)"))
    }

    func testCaptureControlsGuidanceAndStatusCardOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Airwave/OnboardingView.swift"), encoding: .utf8)

        let controls = try XCTUnwrap(source.range(of: "captureTestControls"))
        let guidance = try XCTUnwrap(source.range(of: "captureFailureGuidance(guidance)"))
        let card = try XCTUnwrap(source.range(of: "captureAccessCard"))
        XCTAssertLessThan(card.lowerBound, guidance.lowerBound)
        XCTAssertLessThan(guidance.lowerBound, controls.lowerBound)
        XCTAssertTrue(source.contains("if viewModel.captureFailureGuidance == nil"))
        XCTAssertTrue(source.contains("case .checking, .unverified: return .unknown"))
        XCTAssertTrue(source.contains("case .checking, .unknown: return Color.primary"))
        XCTAssertTrue(source.contains("case .checking:"))
        XCTAssertTrue(source.contains("hasCaptureFailureGuidance"))
        XCTAssertTrue(source.contains("viewModel.canComplete(allowingUnknownCapture: canReturnToSettings)"))
        XCTAssertTrue(source.contains("viewModel.complete(allowingUnknownCapture: canReturnToSettings)"))
        XCTAssertTrue(source.contains("private var isRuntimeReady: Bool"))
        XCTAssertTrue(source.contains("isReady: isRuntimeReady"))
    }

    func testCapturePresentationUsesTruthfulStatesAndActions() {
        XCTAssertEqual(
            OnboardingReadinessPresentation.make(
                captureAccess: .permissionRequired,
                hasPreset: false,
                runtimeStatus: .needsPermission,
                isReady: false
            ).actionStep,
            .systemAudio
        )
        let unknown = OnboardingReadinessPresentation.make(
            captureAccess: .unverified,
            hasPreset: false,
            runtimeStatus: .inactive,
            isReady: false
        )
        XCTAssertFalse(unknown.isAttention)
        XCTAssertEqual(unknown.title, "Capture not confirmed")
        XCTAssertEqual(unknown.actionTitle, "Test System Audio Capture")

        let checking = OnboardingReadinessPresentation.make(
            captureAccess: .checking,
            hasPreset: false,
            runtimeStatus: .starting,
            isReady: false
        )
        XCTAssertFalse(checking.isAttention)
        XCTAssertNil(checking.actionStep)

        let failed = OnboardingReadinessPresentation.make(
            captureAccess: .failed(reason: "Capture test timed out."),
            hasPreset: false,
            runtimeStatus: .nativePassthrough(reason: "Capture test timed out."),
            isReady: false
        )
        XCTAssertTrue(failed.isAttention)
        XCTAssertEqual(failed.actionTitle, "Review Capture")
        XCTAssertNil(
            OnboardingReadinessPresentation.make(
                captureAccess: .verified,
                hasPreset: true,
                runtimeStatus: .processing,
                isReady: true
            ).actionStep
        )
    }

    func testCaptureFailureGuidanceAppearsOnlyForFailedCaptureStates() {
        XCTAssertNil(CaptureFailureGuidance.make(for: .unverified))
        XCTAssertNil(CaptureFailureGuidance.make(for: .checking))
        XCTAssertNil(CaptureFailureGuidance.make(for: .verified))

        let permissionGuidance = CaptureFailureGuidance.make(for: .permissionRequired)
        XCTAssertNotNil(permissionGuidance)
        XCTAssertNil(permissionGuidance?.reason)
        XCTAssertEqual(permissionGuidance?.suggestions.count, 1)

        let failureGuidance = CaptureFailureGuidance.make(for: .failed(reason: "Capture test timed out."))
        XCTAssertEqual(failureGuidance?.reason, "Capture test timed out.")
        XCTAssertEqual(failureGuidance?.suggestions.count, 2)
        XCTAssertTrue(failureGuidance?.suggestions.contains("Enable Airwave under Privacy & Security → System Audio Capture.") == true)
        XCTAssertTrue(failureGuidance?.suggestions.contains("Use a supported physical stereo output; virtual and aggregate outputs are unsupported.") == true)
    }

    func testCompletedSetupDoesNotRequireFreshCaptureWhenInactiveWithoutEffect() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(status: .inactive, captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.needsSetupAttention)
    }

    func testCompletedSetupUnknownCaptureDoesNotShowAttention() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(status: .starting, captureAccess: .checking)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.needsSetupAttention)
    }

    func testVerifiedCaptureCanCompleteWhileRuntimeIsNotYetSteadyState() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .starting,
            currentOutput: output(),
            captureAccess: .verified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertTrue(viewModel.canComplete(allowingUnknownCapture: false))
    }

    func testInitialSetupUnknownCaptureCannotCompleteButSubsequentSetupCan() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: false))
        XCTAssertTrue(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testCompleteUsesSetupEntryContext() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.complete(allowingUnknownCapture: false))
        XCTAssertFalse(persistence.isComplete)
        XCTAssertTrue(viewModel.complete(allowingUnknownCapture: true))
        XCTAssertTrue(persistence.isComplete)
    }

    func testSubsequentSetupCheckingCaptureCannotComplete() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .starting,
            currentOutput: output(),
            captureAccess: .checking
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testKnownFailuresAndUnsupportedCaptureCannotCompleteInEitherSetupContext() {
        let persistence = PersistenceFake()

        for captureAccess in [
            AudioRuntimeState.CaptureAccess.permissionRequired,
            .failed(reason: "capture failed")
        ] {
            let runtime = AudioRuntimeState(
                status: .processing,
                currentOutput: output(),
                captureAccess: captureAccess
            )
            let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

            XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: false), "Unexpectedly allowed initial completion for \(captureAccess)")
            XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true), "Unexpectedly allowed subsequent completion for \(captureAccess)")
        }

        let unsupportedRuntime = AudioRuntimeState(
            status: .processing,
            currentOutput: output(channels: 1),
            captureAccess: .verified
        )
        let unsupportedViewModel = OnboardingViewModel(
            runtime: unsupportedRuntime,
            actions: ActionsFake(),
            persistence: persistence
        )

        XCTAssertFalse(unsupportedViewModel.canComplete(allowingUnknownCapture: false))
        XCTAssertFalse(unsupportedViewModel.canComplete(allowingUnknownCapture: true))
    }

    func testLiveHealthIssueBlocksSubsequentUnknownCaptureCompletion() {
        let persistence = PersistenceFake()
        let runtime = AudioRuntimeState(
            status: .inactive,
            currentOutput: output(),
            captureAccess: .unverified,
            healthIssues: [.captureTestFailed(reason: "current timeout")]
        )
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertFalse(viewModel.canComplete(allowingUnknownCapture: true))
    }

    func testCaptureRequestDelegatesToRuntimeAndFocusRestores() {
        let actions = ActionsFake()
        let focus = FocusFake()
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(), actions: actions, persistence: PersistenceFake(), focusRestorer: focus
        )

        viewModel.requestPermission()
        XCTAssertEqual(actions.requestCount, 1)
        XCTAssertEqual(focus.beginCount, 1)
    }

    func testCaptureFailureGuidanceActionsDelegateToExistingActions() {
        let actions = ActionsFake()
        let viewModel = OnboardingViewModel(
            runtime: AudioRuntimeState(captureAccess: .failed(reason: "silent")),
            actions: actions,
            persistence: PersistenceFake()
        )

        viewModel.openPermissionSettings()
        viewModel.requestPermission()

        XCTAssertEqual(actions.settingsCount, 1)
        XCTAssertEqual(actions.requestCount, 1)
    }

    func testCaptureFailureGuidanceTracksOnlyLiveCaptureState() {
        let runtime = AudioRuntimeState(captureAccess: .failed(reason: "first failure"))
        let persistence = PersistenceFake()
        let viewModel = OnboardingViewModel(
            runtime: runtime,
            actions: ActionsFake(),
            persistence: persistence
        )

        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "first failure")

        runtime.setCaptureAccess(.unverified)
        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertEqual(viewModel.captureAccessPresentation, .unverified)
        runtime.setCaptureAccess(.checking)
        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertEqual(viewModel.captureAccessPresentation, .checking)

        runtime.setCaptureAccess(.failed(reason: "second failure"))
        XCTAssertEqual(viewModel.captureFailureGuidance?.reason, "second failure")

        runtime.setCaptureAccess(.verified)
        XCTAssertNil(viewModel.captureFailureGuidance)
        XCTAssertEqual(viewModel.captureAccessPresentation, .verified)
    }

    func testStartingForcedTestClearsPreviousGuidance() {
        let runtime = AudioRuntimeState(captureAccess: .failed(reason: "previous timeout"))
        let persistence = PersistenceFake()
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        runtime.setCaptureAccess(.checking)
        XCTAssertNil(viewModel.captureFailureGuidance)

        runtime.setCaptureAccess(.verified)

        XCTAssertNil(viewModel.captureFailureGuidance)
    }

    func testLegacyPersistedCaptureFailureIsRemovedWithoutResettingCompletion() throws {
        let suite = "Airwave.ProductSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(UserDefaultsOnboardingPersistenceV2.currentVersion, forKey: "Airwave.OnboardingV2.Version")
        defaults.set(true, forKey: "Airwave.OnboardingV2.Completed")
        defaults.set(Data("legacy failure".utf8), forKey: "Airwave.OnboardingV2.CaptureFailure")

        let persistence = UserDefaultsOnboardingPersistenceV2(defaults: defaults)

        XCTAssertTrue(persistence.isComplete)
        XCTAssertNil(defaults.object(forKey: "Airwave.OnboardingV2.CaptureFailure"))
    }

    func testUnknownCaptureWithoutPersistedFailureRemainsUnverifiedPresentation() {
        let runtime = AudioRuntimeState(captureAccess: .unverified)
        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: PersistenceFake())

        XCTAssertEqual(viewModel.captureAccessPresentation, .unverified)
    }

    func testCurrentHealthIssueShowsAttentionAndRoutesCompletedSetupToHealth() {
        let persistence = PersistenceFake()
        persistence.isComplete = true
        let runtime = AudioRuntimeState(
            currentOutput: output(),
            captureAccess: .verified,
            healthIssues: [.equalizerFailed(reason: "invalid filter")]
        )

        let viewModel = OnboardingViewModel(runtime: runtime, actions: ActionsFake(), persistence: persistence)

        XCTAssertTrue(viewModel.needsSetupAttention)
        XCTAssertEqual(viewModel.recommendedVoluntaryEntryStep, .liveHealth)
        XCTAssertEqual(RuntimeHealthIssuePresentation.make(for: runtime.healthIssues[0]).action, .openEqualizer)
    }

    func testEveryHealthIssueHasCategorySpecificRecoveryPresentation() {
        let cases: [(RuntimeHealthIssue, RuntimeHealthRecoveryAction)] = [
            (.permissionRequired, .reviewCapture),
            (.captureTestFailed(reason: "timeout"), .reviewCapture),
            (.noUsableOutput, .retry),
            (.unsupportedOutput(reason: "virtual"), .retry),
            (.audioPipelineFailed(reason: "format"), .retry),
            (.resourceRecovery(reason: "cleanup"), .retry),
            (.spatialPresetFailed(reason: "HRIR"), .chooseHRIR),
            (.equalizerFailed(reason: "filter"), .openEqualizer)
        ]

        for (issue, expectedAction) in cases {
            let presentation = RuntimeHealthIssuePresentation.make(for: issue)
            XCTAssertEqual(presentation.action, expectedAction)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.detail.isEmpty)
            XCTAssertFalse(presentation.suggestions.isEmpty)
        }
    }

    func testFirstRunDefaultsEnableLaunchAtLoginAndHideMenuBarItem() throws {
        let suite = "Airwave.ProductSetupDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let loginItem = LoginItemAdapterFake()
        let launchAtLogin = LaunchAtLoginManager(adapter: loginItem)
        let migrated = try SettingsSchemaV2Migrator(
            defaults: defaults,
            launchAtLogin: launchAtLogin
        ).migrateIfNeeded()
        let menuVisibility = MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {})

        XCTAssertTrue(migrated)
        XCTAssertTrue(launchAtLogin.isEnabled)
        XCTAssertEqual(loginItem.registerCount, 1)
        XCTAssertFalse(menuVisibility.isVisible)
    }

    func testExistingMenuBarPreferenceIsPreserved() throws {
        let suite = "Airwave.ProductSetupDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MenuBarVisibilityManager.defaultsKey)

        let menuVisibility = MenuBarVisibilityManager(defaults: defaults, visibilityDidChange: {})

        XCTAssertTrue(menuVisibility.isVisible)
    }

    private func output(channels: Int = 2) -> OutputDeviceDescriptor {
        OutputDeviceDescriptor(
            id: .init(1), uid: "built-in", name: "Built-in Output", transport: "Built-in",
            outputChannelCount: channels, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false
        )
    }
}

private func applicationEvent(
    id: AEEventID,
    loginItem: Bool = false
) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass),
        eventID: id,
        targetDescriptor: nil,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    if loginItem {
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )
    }
    return event
}

@MainActor
private final class AppleEventRouterFake: ApplicationAppleEventRouting {
    struct Registration {
        let selector: Selector
        let eventClass: AEEventClass
        let eventID: AEEventID
    }

    private(set) var registrations: [Registration] = []

    func register(
        target: NSObject,
        selector: Selector,
        eventClass: AEEventClass,
        eventID: AEEventID
    ) {
        registrations.append(Registration(selector: selector, eventClass: eventClass, eventID: eventID))
    }

    func remove(eventClass: AEEventClass, eventID: AEEventID) {}
}

@MainActor
private final class ApplicationLifecycleApplicationFake: ApplicationLifecycleApplication {
    let windows: [NSWindow] = []
    private(set) var terminateCallCount = 0

    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        true
    }

    func terminate(_ sender: Any?) {
        terminateCallCount += 1
    }
}

@MainActor
private final class AppleEventSenderResolverFake: AppleEventSenderResolving {
    var bundleIdentifier: String?
    private(set) var resolutionCount = 0

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
    }

    func bundleIdentifier(for event: NSAppleEventDescriptor) -> String? {
        resolutionCount += 1
        return bundleIdentifier
    }
}

@MainActor
private final class LoginItemAdapterFake: LoginItemAdapting {
    var isEnabled = false
    var registerCount = 0

    func register() throws {
        registerCount += 1
        isEnabled = true
    }

    func unregister() throws {
        isEnabled = false
    }
}

@MainActor
private final class ActionsFake: AudioRuntimeUserActions {
    var requestCount = 0
    var settingsCount = 0
    func requestSystemAudioAccess() { requestCount += 1 }
    func retryNow() {}
    func openSystemAudioRecordingSettings() { settingsCount += 1 }
}

@MainActor
private final class FocusFake: PermissionFocusRestoring {
    var beginCount = 0
    func beginPermissionRequest() { beginCount += 1 }
    func permissionRequestResolved() {}
}

private final class PersistenceFake: OnboardingPersisting {
    var version = 2
    var checkpoint: OnboardingStepV2 = .welcome
    var isComplete = false
    var isDeferred = false
}
