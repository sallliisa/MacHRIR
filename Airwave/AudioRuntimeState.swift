import Foundation
import Combine

nonisolated enum RuntimeHealthIssue: Equatable, Sendable {
    enum Category: Int, CaseIterable, Sendable {
        case permission
        case output
        case capture
        case pipeline
        case recovery
        case spatial
        case equalizer
        case coexistence
    }

    case permissionRequired
    case noUsableOutput
    case unsupportedOutput(reason: String)
    case captureTestFailed(reason: String)
    case audioPipelineFailed(reason: String)
    case resourceRecovery(reason: String)
    case spatialPresetFailed(reason: String)
    case equalizerFailed(reason: String)
    case incompatibleAudioApp(appNames: [String])

    var category: Category {
        switch self {
        case .permissionRequired: .permission
        case .noUsableOutput, .unsupportedOutput: .output
        case .captureTestFailed: .capture
        case .audioPipelineFailed: .pipeline
        case .resourceRecovery: .recovery
        case .spatialPresetFailed: .spatial
        case .equalizerFailed: .equalizer
        case .incompatibleAudioApp: .coexistence
        }
    }
}

@MainActor
final class AudioRuntimeState: ObservableObject {
    enum CaptureAccess: Equatable {
        case unverified
        case checking
        case verified
        case permissionRequired
        case failed(reason: String)
    }

    enum Status: Equatable {
        case unavailable(String)
        case inactive
        case needsPermission
        case nativePassthrough(reason: String)
        case starting
        case processing
        case recovering(reason: String)

        var title: String {
            switch self {
            case .unavailable: "Unavailable"
            case .inactive: "Inactive"
            case .needsPermission: "Permission required"
            case .nativePassthrough: "Native passthrough"
            case .starting: "Starting"
            case .processing: "Processing"
            case .recovering: "Recovering"
            }
        }

        var detail: String {
            switch self {
            case .unavailable(let reason), .nativePassthrough(let reason), .recovering(let reason):
                reason
            case .inactive:
                "No HRIR preset selected; native audio remains unchanged."
            case .needsPermission:
                "System Audio Capture needs access before processing can start."
            case .starting:
                "Airwave is preparing native audio processing."
            case .processing:
                "Airwave is processing audio without changing macOS output or volume."
            }
        }

        var isProcessing: Bool { self == .processing }
    }

    static let shared = AudioRuntimeState()

    @Published private(set) var status: Status
    @Published private(set) var captureAccess: CaptureAccess
    @Published private(set) var currentOutput: OutputDeviceDescriptor?
    @Published private(set) var warningMessage: String?
    @Published private(set) var healthIssues: [RuntimeHealthIssue]

    init(
        status: Status = .unavailable("Airwave 2.0 audio backend is not installed yet"),
        currentOutput: OutputDeviceDescriptor? = nil,
        warningMessage: String? = nil,
        captureAccess: CaptureAccess = .unverified,
        healthIssues: [RuntimeHealthIssue] = []
    ) {
        self.status = status
        self.captureAccess = captureAccess
        self.currentOutput = currentOutput
        self.warningMessage = warningMessage
        self.healthIssues = Self.sortedIssues(healthIssues)
    }

    func setCaptureAccess(_ captureAccess: CaptureAccess) {
        self.captureAccess = captureAccess
    }

    var isSetupHealthy: Bool {
        captureAccess == .verified
            && (currentOutput?.isSupportedProfileOutput == true)
            && healthIssues.isEmpty
    }

    var hasBlockingHealthIssue: Bool { !healthIssues.isEmpty }

    func setHealthIssue(_ issue: RuntimeHealthIssue?, for category: RuntimeHealthIssue.Category) {
        var issuesByCategory = Dictionary(uniqueKeysWithValues: healthIssues.map { ($0.category, $0) })
        issuesByCategory[category] = issue
        healthIssues = Self.sortedIssues(Array(issuesByCategory.values))
    }

    func clearHealthIssues() {
        healthIssues = []
    }

    func publish(
        _ status: Status,
        output: OutputDeviceDescriptor? = nil,
        warning: String? = nil,
        captureAccess: CaptureAccess? = nil
    ) {
        if let captureAccess { self.captureAccess = captureAccess }
        self.currentOutput = output
        self.status = status
        self.warningMessage = warning
    }

    private static func sortedIssues(_ issues: [RuntimeHealthIssue]) -> [RuntimeHealthIssue] {
        let issuesByCategory = Dictionary(uniqueKeysWithValues: issues.map { ($0.category, $0) })
        return RuntimeHealthIssue.Category.allCases.compactMap { issuesByCategory[$0] }
    }
}
