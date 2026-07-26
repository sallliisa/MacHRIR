import AppKit
import SwiftUI

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")
    static let contentSize = NSSize(width: 900, height: 600)
    private static var settingsWindow: NSWindow?
    private static var settingsWindowController: NSWindowController?
    private static let contentState = SettingsWindowContentState()

    static func register(_ window: NSWindow) {
        settingsWindow = window
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
        configureCustomChrome(window)
        window.styleMask.remove(.resizable)
        let fixedSize = contentSize
        window.contentMinSize = fixedSize
        window.contentMaxSize = fixedSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
    }

    private static func configureCustomChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = AirwavePalette.canvasNSColor
    }

    static func presentExistingWindow() {
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
        WindowFronting.present(identifier: windowIdentifier, title: "Settings")
    }

    static func present(_ mode: SettingsWindowContentState.Mode = .settings) {
        contentState.show(
            mode,
            canReturnToSettings: mode == .setup && OnboardingViewModel.shared.isComplete
        )
        if settingsWindow == nil {
            let content = SettingsWindowContent(state: contentState)
                .environmentObject(MenuBarViewModel.shared)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrameAutosaveName("com.southneuhof.Airwave.settings.frame")
            let windowController = NSWindowController(window: window)
            windowController.shouldCascadeWindows = true
            settingsWindowController = windowController
            register(window)
            windowController.showWindow(nil)
        }
        presentExistingWindow()
    }
}
