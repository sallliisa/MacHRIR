import AppKit
import Foundation

/// One rule matching a running application known to install always-on Core Audio
/// process taps. Any provided field matching is enough for the rule to match.
nonisolated struct ConflictingTapAppRule: Sendable, Equatable {
    let bundleIDExact: String?
    let bundleIDContains: String?
    let localizedName: String?

    init(bundleIDExact: String? = nil, bundleIDContains: String? = nil, localizedName: String? = nil) {
        self.bundleIDExact = bundleIDExact
        self.bundleIDContains = bundleIDContains
        self.localizedName = localizedName
    }

    /// Per-app volume utilities tap every audio-producing process and mute what
    /// they tap. Airwave's own global muted tap then captures their replay, and
    /// the two processes trade muted audio that never reaches the hardware.
    static let knownRules: [ConflictingTapAppRule] = [
        ConflictingTapAppRule(bundleIDExact: "com.finetuneapp.FineTune", localizedName: "FineTune"),
        ConflictingTapAppRule(bundleIDContains: "betteraudio", localizedName: "BetterAudio")
    ]

    func matches(bundleID: String?, name: String?) -> Bool {
        if let bundleIDExact, let bundleID, bundleID == bundleIDExact { return true }
        if let bundleIDContains, let bundleID,
           bundleID.range(of: bundleIDContains, options: .caseInsensitive) != nil { return true }
        if let localizedName, let name, name == localizedName { return true }
        return false
    }
}

@MainActor
protocol ConflictAppSource: AnyObject {
    func runningApps() -> [(bundleID: String?, name: String?)]
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

@MainActor
final class WorkspaceConflictAppSource: ConflictAppSource {
    private var observers: [NSObjectProtocol] = []

    func runningApps() -> [(bundleID: String?, name: String?)] {
        NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) }
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
    }

    func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
    }
}

/// Watches for running apps that would deadlock Airwave's processing tap.
@MainActor
final class TapConflictMonitor {
    nonisolated struct Snapshot: Equatable, Sendable {
        let appNames: [String]

        init(appNames: [String] = []) { self.appNames = appNames }

        var isEmpty: Bool { appNames.isEmpty }
        static let none = Snapshot()
    }

    static let shared = TapConflictMonitor()

    private let rules: [ConflictingTapAppRule]
    private let source: ConflictAppSource
    private var snapshot: Snapshot = .none
    private var observing = false

    var onChange: ((Snapshot) -> Void)?

    init(
        rules: [ConflictingTapAppRule] = ConflictingTapAppRule.knownRules,
        source: ConflictAppSource? = nil
    ) {
        self.rules = rules
        self.source = source ?? WorkspaceConflictAppSource()
    }

    deinit { MainActor.assumeIsolated { source.stopObserving() } }

    /// Rescans and returns the current snapshot. Safe to call before `start()`.
    @discardableResult
    func currentSnapshot() -> Snapshot {
        snapshot = scan()
        return snapshot
    }

    func start() {
        guard !observing else { return }
        observing = true
        snapshot = scan()
        source.startObserving { [weak self] in self?.rescan() }
    }

    func stop() {
        guard observing else { return }
        observing = false
        source.stopObserving()
    }

    private func rescan() {
        let updated = scan()
        guard updated != snapshot else { return }
        snapshot = updated
        onChange?(updated)
    }

    private func scan() -> Snapshot {
        var names: [String] = []
        for app in source.runningApps() where rules.contains(where: { $0.matches(bundleID: app.bundleID, name: app.name) }) {
            let name = app.name ?? app.bundleID ?? "Unknown app"
            if !names.contains(name) { names.append(name) }
        }
        return Snapshot(appNames: names)
    }
}
