import AppKit
import Combine
import os
import SwiftUI

@MainActor
protocol ApplicationLifecycleApplication: ApplicationActivationPolicyApplying {
    var windows: [NSWindow] { get }
    func terminate(_ sender: Any?)
}

extension NSApplication: ApplicationLifecycleApplication {}

nonisolated enum LaunchWindowAction: Equatable {
    case none
    case setup
    case settings
}

nonisolated enum LaunchWindowEvent: Equatable {
    case loginItemLaunch
    case userColdOpen
    case userReopen
}

nonisolated struct LaunchWindowPendingAction: Equatable {
    let event: LaunchWindowEvent
    let action: LaunchWindowAction
}

nonisolated struct AppleEventDeliveryToken: Hashable {
    let eventClass: AEEventClass
    let eventID: AEEventID
    let returnID: AEReturnID
    let transactionID: AETransactionID

    init(event: NSAppleEventDescriptor) {
        eventClass = event.eventClass
        eventID = event.eventID
        returnID = event.returnID
        transactionID = event.transactionID
    }
}

nonisolated enum LaunchWindowPolicy {
    static func action(
        for event: LaunchWindowEvent,
        setupIsComplete: Bool,
        showsMenuBar: Bool
    ) -> LaunchWindowAction {
        switch event {
        case .loginItemLaunch:
            return .none
        case .userColdOpen, .userReopen:
            return userOpen(setupIsComplete: setupIsComplete, showsMenuBar: showsMenuBar)
        }
    }

    private static func userOpen(
        setupIsComplete: Bool,
        showsMenuBar: Bool
    ) -> LaunchWindowAction {
        _ = showsMenuBar // User opens always present a window, independent of menu-bar visibility.
        return setupIsComplete ? .settings : .setup
    }
}

nonisolated struct LaunchWindowCoordinator: Equatable {
    private var handledDeliveryTokens: Set<AppleEventDeliveryToken> = []
    private var pendingEvents: [LaunchWindowEvent] = []

    mutating func action(
        for event: LaunchWindowEvent,
        setupIsComplete: Bool,
        showsMenuBar: Bool,
        isReady: Bool = true,
        deliveryToken: AppleEventDeliveryToken? = nil
    ) -> LaunchWindowAction {
        guard accept(deliveryToken) else { return .none }
        guard isReady else {
            pendingEvents.append(event)
            return .none
        }
        return LaunchWindowPolicy.action(
            for: event,
            setupIsComplete: setupIsComplete,
            showsMenuBar: showsMenuBar
        )
    }

    mutating func drainPendingActions(
        setupIsComplete: Bool,
        showsMenuBar: Bool
    ) -> [LaunchWindowPendingAction] {
        let events = pendingEvents
        pendingEvents.removeAll()
        return events.map {
            LaunchWindowPendingAction(
                event: $0,
                action: LaunchWindowPolicy.action(
                    for: $0,
                    setupIsComplete: setupIsComplete,
                    showsMenuBar: showsMenuBar
                )
            )
        }
    }

    private mutating func accept(_ deliveryToken: AppleEventDeliveryToken?) -> Bool {
        guard let deliveryToken else { return true }
        return handledDeliveryTokens.insert(deliveryToken).inserted
    }
}

nonisolated enum LaunchWindowAppleEventClassifier {
    static let loginWindowBundleIdentifier = "com.apple.loginwindow"

    static func event(
        for descriptor: NSAppleEventDescriptor,
        senderBundleIdentifier: String? = nil
    ) -> LaunchWindowEvent? {
        guard descriptor.eventClass == AEEventClass(kCoreEventClass) else { return nil }
        switch descriptor.eventID {
        case AEEventID(kAEOpenApplication):
            if descriptor.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil {
                return .loginItemLaunch
            }
            if senderBundleIdentifier == loginWindowBundleIdentifier {
                return .loginItemLaunch
            }
            return .userColdOpen
        case AEEventID(kAEReopenApplication):
            if senderBundleIdentifier == loginWindowBundleIdentifier {
                return .loginItemLaunch
            }
            return .userReopen
        default:
            return nil
        }
    }
}

@MainActor
protocol AppleEventSenderResolving {
    func bundleIdentifier(for event: NSAppleEventDescriptor) -> String?
}

struct SystemAppleEventSenderResolver: AppleEventSenderResolving {
    nonisolated init() {}

    @MainActor
    func bundleIdentifier(for event: NSAppleEventDescriptor) -> String? {
        guard let pidDescriptor = event.attributeDescriptor(
            forKeyword: AEKeyword(keySenderPIDAttr)
        ) else { return nil }

        let pid = pidDescriptor.int32Value
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }
}

@MainActor
protocol ApplicationAppleEventRouting: AnyObject {
    func register(
        target: NSObject,
        selector: Selector,
        eventClass: AEEventClass,
        eventID: AEEventID
    )
    func remove(eventClass: AEEventClass, eventID: AEEventID)
}

extension NSAppleEventManager: ApplicationAppleEventRouting {
    func register(
        target: NSObject,
        selector: Selector,
        eventClass: AEEventClass,
        eventID: AEEventID
    ) {
        setEventHandler(target, andSelector: selector, forEventClass: eventClass, andEventID: eventID)
    }

    func remove(eventClass: AEEventClass, eventID: AEEventID) {
        removeEventHandler(forEventClass: eventClass, andEventID: eventID)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let launchRoutingLogger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.southneuhof.Airwave",
        category: "LaunchRouting"
    )

    private let appleEventRouter: ApplicationAppleEventRouting
    private let appleEventSenderResolver: AppleEventSenderResolving
    private var launchWindowCoordinator = LaunchWindowCoordinator()
    private var runtimeIsReady = false

    init(
        appleEventRouter: ApplicationAppleEventRouting = NSAppleEventManager.shared(),
        senderResolver: AppleEventSenderResolving = SystemAppleEventSenderResolver()
    ) {
        self.appleEventRouter = appleEventRouter
        self.appleEventSenderResolver = senderResolver
        super.init()
    }

    override convenience init() {
        self.init(
            appleEventRouter: NSAppleEventManager.shared(),
            senderResolver: SystemAppleEventSenderResolver()
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let eventClass = AEEventClass(kCoreEventClass)
        appleEventRouter.register(
            target: self,
            selector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            eventClass: eventClass,
            eventID: AEEventID(kAEOpenApplication)
        )
        appleEventRouter.register(
            target: self,
            selector: #selector(handleReopenApplicationEvent(_:withReplyEvent:)),
            eventClass: eventClass,
            eventID: AEEventID(kAEReopenApplication)
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AudioRuntimeController.shared.refreshSystemAudioAccess()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("[AppDelegate] Airwave safe shell launched")
        ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
        // Seed the conflict state before the first reconcile so an already
        // running tap-based volume app never gets a processing tap, even briefly.
        let tapConflicts = TapConflictMonitor.shared
        tapConflicts.onChange = { AudioRuntimeController.shared.tapConflictsChanged($0) }
        AudioRuntimeController.shared.tapConflictsChanged(tapConflicts.currentSnapshot())
        tapConflicts.start()
        DeviceProfileRuntimeCoordinator.shared.launch()
        OutputDeviceDiscoveryCoordinator.shared.launch()
        runtimeIsReady = true
        drainPendingLaunchWindowEvents()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )

    }

    func applicationWillTerminate(_ notification: Notification) {
        let eventClass = AEEventClass(kCoreEventClass)
        appleEventRouter.remove(eventClass: eventClass, eventID: AEEventID(kAEOpenApplication))
        appleEventRouter.remove(eventClass: eventClass, eventID: AEEventID(kAEReopenApplication))
        AudioRuntimeController.shared.terminate()
        Logger.log("[AppDelegate] Airwave safe shell terminating")
    }

    func applicationWillResignActive(_ notification: Notification) {
        AudioRuntimeController.shared.applicationWillResignActive()
        ApplicationLifecycleCoordinator.shared.applicationWillResignActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationLifecycleCoordinator.shared.terminationReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }


    private func presentWindow(for action: LaunchWindowAction) {
        switch action {
        case .none:
            break
        case .setup:
            OnboardingViewModel.shared.prepareForPresentation(.automaticFirstSetup)
            SettingsWindowPresenter.present(.setup)
        case .settings:
            SettingsWindowPresenter.present(.settings)
        }
    }

    @objc func handleOpenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        route(event: event)
    }

    @objc func handleReopenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        route(event: event)
    }

    private func route(event: NSAppleEventDescriptor) {
        let senderBundleIdentifier = appleEventSenderResolver.bundleIdentifier(for: event)
        guard let launchEvent = LaunchWindowAppleEventClassifier.event(
            for: event,
            senderBundleIdentifier: senderBundleIdentifier
        ) else { return }
        let action = launchWindowCoordinator.action(
            for: launchEvent,
            setupIsComplete: OnboardingViewModel.shared.isComplete,
            showsMenuBar: MenuBarVisibilityManager.shared.isVisible,
            isReady: runtimeIsReady,
            deliveryToken: AppleEventDeliveryToken(event: event)
        )
        Logger.log("[AppDelegate] Apple event \(launchEvent) -> \(action)")
        logLaunchRouting(
            event: event,
            intent: launchEvent,
            action: action,
            senderBundleIdentifier: senderBundleIdentifier,
            phase: runtimeIsReady ? "routed" : "queued"
        )
        presentWindow(for: action)
    }

    private func drainPendingLaunchWindowEvents() {
        let actions = launchWindowCoordinator.drainPendingActions(
            setupIsComplete: OnboardingViewModel.shared.isComplete,
            showsMenuBar: MenuBarVisibilityManager.shared.isVisible
        )
        actions.forEach {
            Logger.log("[AppDelegate] Queued Apple event \($0.event) -> \($0.action)")
            Self.launchRoutingLogger.info(
                "event=\(self.eventKind(for: $0.event), privacy: .public) intent=\(self.intentName(for: $0.event), privacy: .public) action=\(self.actionName(for: $0.action), privacy: .public) phase=drained"
            )
            self.presentWindow(for: $0.action)
        }
    }

    private func logLaunchRouting(
        event: NSAppleEventDescriptor,
        intent: LaunchWindowEvent,
        action: LaunchWindowAction,
        senderBundleIdentifier: String?,
        phase: String
    ) {
        let markerPresent = event.paramDescriptor(
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        ) != nil
        Self.launchRoutingLogger.info(
            "event=\(self.eventKind(for: event.eventID), privacy: .public) marker=\(markerPresent, privacy: .public) sender=\(senderBundleIdentifier ?? "unresolved", privacy: .public) intent=\(self.intentName(for: intent), privacy: .public) action=\(self.actionName(for: action), privacy: .public) phase=\(phase, privacy: .public)"
        )
    }

    private func eventKind(for eventID: AEEventID) -> String {
        eventID == AEEventID(kAEOpenApplication) ? "open" : "reopen"
    }

    private func eventKind(for event: LaunchWindowEvent) -> String {
        switch event {
        case .loginItemLaunch, .userColdOpen: "open"
        case .userReopen: "reopen"
        }
    }

    private func intentName(for event: LaunchWindowEvent) -> String {
        switch event {
        case .loginItemLaunch: "loginItemLaunch"
        case .userColdOpen: "userColdOpen"
        case .userReopen: "userReopen"
        }
    }

    private func actionName(for action: LaunchWindowAction) -> String {
        switch action {
        case .none: "none"
        case .setup: "setup"
        case .settings: "settings"
        }
    }

    @objc private func willSleep() { AudioRuntimeController.shared.willSleep() }
    @objc private func didWake() { AudioRuntimeController.shared.didWake() }
    @objc private func willPowerOff() { ApplicationLifecycleCoordinator.shared.beginSystemTermination() }
}
