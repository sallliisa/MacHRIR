import AppKit
import Foundation

@MainActor
final class ApplicationLifecycleCoordinator: NSObject {
    static let shared = ApplicationLifecycleCoordinator(
        application: NSApplication.shared
    )

    static let aboutWindowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.about")

    private let application: ApplicationLifecycleApplication
    private var explicitQuitRequested = false
    private var systemTerminationRequested = false
    private var updateRelaunchTerminationRequested = false
    private var observesWindows = false
    private var appliedActivationPolicy: NSApplication.ActivationPolicy?
    private var pendingFocusedSpaceDeparture = false
    private var restoreFocusOnSpaceReturn = false
    private var focusDepartureGeneration = 0

    init(
        application: ApplicationLifecycleApplication,
        observeWindows: Bool = true
    ) {
        self.application = application
        super.init()
        guard observeWindows else { return }
        observesWindows = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.willCloseNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        if observesWindows {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    static func activationPolicy(hasVisibleUserWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleUserWindow ? .regular : .accessory
    }

    func prepareToPresentUserWindow() {
        apply(.regular)
    }

    func updateActivationPolicy() {
        let hasVisibleWindow = application.windows.contains(where: Self.isUserFacingWindow)
        updateActivationPolicy(hasVisibleUserWindow: hasVisibleWindow)
    }

    func updateActivationPolicy(hasVisibleUserWindow: Bool) {
        apply(Self.activationPolicy(hasVisibleUserWindow: hasVisibleUserWindow))
    }

    func closeAllUserWindows() {
        application.windows.filter {
            Self.isUserFacingWindow($0) || Self.isMenuBarPopover($0)
        }.forEach { $0.close() }
        updateActivationPolicy(hasVisibleUserWindow: false)
    }

    func requestExplicitQuit() {
        explicitQuitRequested = true
        application.terminate(nil)
    }

    func beginSystemTermination() {
        systemTerminationRequested = true
    }

    func beginUpdateRelaunchTermination() {
        updateRelaunchTerminationRequested = true
    }

    func applicationWillResignActive() {
        guard let window = settingsWindow, window.isKeyWindow, !window.isMiniaturized else {
            pendingFocusedSpaceDeparture = false
            return
        }
        pendingFocusedSpaceDeparture = true
        focusDepartureGeneration += 1
        let generation = focusDepartureGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == focusDepartureGeneration, !restoreFocusOnSpaceReturn else { return }
            pendingFocusedSpaceDeparture = false
        }
    }

    func terminationReply() -> NSApplication.TerminateReply {
        if explicitQuitRequested || systemTerminationRequested || updateRelaunchTerminationRequested {
            explicitQuitRequested = false
            updateRelaunchTerminationRequested = false
            return .terminateNow
        }
        closeAllUserWindows()
        return .terminateCancel
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard appliedActivationPolicy != policy else { return }
        guard application.setActivationPolicy(policy) else {
            Logger.log("[Application] Could not apply \(policy == .regular ? "regular" : "accessory") activation policy")
            return
        }
        appliedActivationPolicy = policy
        Logger.log("[Application] Activation policy is \(policy == .regular ? "regular" : "accessory")")
    }

    static func isUserFacingWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        if window.identifier == SettingsWindowPresenter.windowIdentifier
            || window.identifier == aboutWindowIdentifier {
            return true
        }
        guard !isMenuBarPopover(window) else { return false }
        return window.canBecomeMain && window.styleMask.contains(.titled) && !window.title.isEmpty
    }

    private static func isMenuBarPopover(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let className = window.className.lowercased()
        return className.contains("menubar") || className.contains("popover")
    }

    private var settingsWindow: NSWindow? {
        application.windows.first { $0.identifier == SettingsWindowPresenter.windowIdentifier }
    }

    @objc private func activeSpaceDidChange() {
        guard let window = settingsWindow, !window.isMiniaturized else {
            pendingFocusedSpaceDeparture = false
            restoreFocusOnSpaceReturn = false
            return
        }

        if pendingFocusedSpaceDeparture, !window.isOnActiveSpace {
            pendingFocusedSpaceDeparture = false
            restoreFocusOnSpaceReturn = true
            return
        }

        guard restoreFocusOnSpaceReturn, window.isOnActiveSpace else { return }
        restoreFocusOnSpaceReturn = false
        prepareToPresentUserWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func windowStateChanged() {
        Task { @MainActor in
            await Task.yield()
            updateActivationPolicy()
        }
    }
}
