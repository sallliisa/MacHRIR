import AppKit

@MainActor
enum WindowFronting {
    static func present(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        retriesRemaining: Int = 5
    ) {
        if let window = NSApp.windows.first(where: { $0.identifier == identifier || $0.title == title }) {
            window.identifier = identifier
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.hidesOnDeactivate = false
            if window.isMiniaturized { window.deminiaturize(nil) }

            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)

            Task { @MainActor in
                await Task.yield()
                guard window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard window.isVisible else { return }
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard retriesRemaining > 0 else { return }
        Task { @MainActor in
            await Task.yield()
            present(identifier: identifier, title: title, retriesRemaining: retriesRemaining - 1)
        }
    }
}
