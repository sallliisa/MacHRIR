import XCTest
@testable import Airwave

@MainActor
final class TapConflictMonitorTests: XCTestCase {
    func testExactBundleIDMatches() {
        let source = AppSourceFake(apps: [(bundleID: "com.finetuneapp.FineTune", name: "FineTune")])
        let monitor = TapConflictMonitor(source: source)

        XCTAssertEqual(monitor.currentSnapshot(), .init(appNames: ["FineTune"]))
    }

    func testBundleIDContainsIsCaseInsensitive() {
        let source = AppSourceFake(apps: [(bundleID: "pro.BetterAudio.app", name: "Better Audio Pro")])
        let monitor = TapConflictMonitor(source: source)

        XCTAssertEqual(monitor.currentSnapshot(), .init(appNames: ["Better Audio Pro"]))
    }

    func testLocalizedNameMatchesWhenBundleIDDiffers() {
        let source = AppSourceFake(apps: [(bundleID: "com.example.unknown", name: "BetterAudio")])
        let monitor = TapConflictMonitor(source: source)

        XCTAssertEqual(monitor.currentSnapshot(), .init(appNames: ["BetterAudio"]))
    }

    func testUnrelatedAppsAreIgnored() {
        let source = AppSourceFake(apps: [
            (bundleID: "com.apple.Music", name: "Music"),
            (bundleID: "com.airwave.Airwave", name: "Airwave")
        ])
        let monitor = TapConflictMonitor(source: source)

        XCTAssertTrue(monitor.currentSnapshot().isEmpty)
    }

    func testLaunchAndTerminateEachFireOnChangeOnce() {
        let source = AppSourceFake(apps: [])
        let monitor = TapConflictMonitor(source: source)
        var snapshots: [TapConflictMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }
        monitor.start()

        source.apps = [(bundleID: "com.finetuneapp.FineTune", name: "FineTune")]
        source.notify()
        source.notify() // rescan with identical results

        XCTAssertEqual(snapshots, [.init(appNames: ["FineTune"])])

        source.apps = []
        source.notify()

        XCTAssertEqual(snapshots, [.init(appNames: ["FineTune"]), .init(appNames: [])])
    }

    func testStopEndsObservation() {
        let source = AppSourceFake(apps: [])
        let monitor = TapConflictMonitor(source: source)
        monitor.start()
        XCTAssertTrue(source.isObserving)

        monitor.stop()

        XCTAssertFalse(source.isObserving)
    }
}

@MainActor
private final class AppSourceFake: ConflictAppSource {
    var apps: [(bundleID: String?, name: String?)]
    private(set) var isObserving = false
    private var handler: (@MainActor () -> Void)?

    init(apps: [(bundleID: String?, name: String?)]) { self.apps = apps }

    func runningApps() -> [(bundleID: String?, name: String?)] { apps }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        isObserving = true
        handler = onChange
    }

    func stopObserving() {
        isObserving = false
        handler = nil
    }

    func notify() { handler?() }
}
