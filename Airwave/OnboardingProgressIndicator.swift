import SwiftUI

struct OnboardingProgressIndicator: View {
    let currentStep: OnboardingStepV2
    let permission: CaptureAccessPresentation
    let hasCaptureFailureGuidance: Bool
    let hasPreset: Bool
    let isReady: Bool
    let onSelect: (OnboardingStepV2) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStepV2.allCases, id: \.self) { step in
                OnboardingProgressItem(
                    step: step,
                    status: status(for: step),
                    isCurrent: currentStep == step,
                    action: { onSelect(step) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }

    private func status(for step: OnboardingStepV2) -> ProgressStatus {
        switch step {
        case .welcome: return .complete
        case .systemAudio:
            if hasCaptureFailureGuidance { return .attention }
            switch permission {
            case .verified: return .complete
            case .permissionRequired, .failed: return .attention
            case .checking, .unverified: return .unknown
            }
        case .hrirPreset: return .complete
        case .liveHealth: return isReady ? .complete : .incomplete
        }
    }
}

private enum ProgressStatus {
    case checking
    case unknown
    case incomplete
    case attention
    case complete
}

private struct OnboardingProgressItem: View {
    let step: OnboardingStepV2
    let status: ProgressStatus
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: step.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background { Circle().fill(indicatorBackground) }
                .contentShape(Circle())
        }
        .buttonStyle(AirwavePressedButtonStyle())
        .help("\(step.title) — \(statusDescription)")
        .accessibilityLabel(step.title)
        .accessibilityValue(isCurrent ? "Current page, \(statusDescription)" : statusDescription)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }

    private var iconColor: Color {
        if isCurrent { return AirwavePalette.canvas }
        switch status {
        case .complete: return Color.white
        case .attention: return Color.orange
        case .checking, .unknown: return Color.primary
        case .incomplete: return Color.secondary
        }
    }

    private var indicatorBackground: Color {
        if isCurrent { return Color.primary.opacity(isHovering ? 0.78 : 0.92) }
        return isHovering ? AirwavePalette.hover : .clear
    }

    private var statusDescription: String {
        switch status {
        case .checking: "Checking"
        case .unknown: "Not checked"
        case .incomplete: "Needs setup"
        case .attention: "Action needed"
        case .complete: "Complete"
        }
    }
}
