import AppKit
import SwiftUI

enum AirwavePalette {
    static let canvas = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    /// AppKit twin of `canvas`, for window chrome.
    static let canvasNSColor = NSColor(red: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
    static let raised = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
    static let hover = Color.white.opacity(0.08)
}

nonisolated enum AirwaveResourceLinks {
    static let hrir = URL(string: "https://airtable.com/embed/appac4r1cu9UpBNAN/shrpUAbtyZxhDDMjg/tblopH2GznvFipWjq/viwnouWPGDuYEd8Go")!
    static let equalizer = URL(string: "https://autoeq.app/")!
}

enum AirwaveLayout {
    static let sectionSpacing: CGFloat = 16
    static let sectionContentSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 8
    static let pageHeaderContentMinimumSpacing: CGFloat = 24
    static let compactPageHorizontalPadding: CGFloat = 30
    static let compactPageTopPadding: CGFloat = 94
    static let compactPageBottomPadding: CGFloat = 104
    static let compactPageMaxWidth: CGFloat = 680
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 8
    static let menuGroupPadding: CGFloat = 4
    static let menuRowHorizontalPadding: CGFloat = 12
    static let menuRowVerticalPadding: CGFloat = 6
    static let menuOuterPadding: CGFloat = 6
    static let menuDividerInset: CGFloat = 10
}

enum AirwaveMotion {
    static let pageTransitionDuration: TimeInterval = 0.3
    static let pageTransition: Animation = .smooth(duration: pageTransitionDuration)
}

enum AirwavePageLayoutMode: Equatable {
    case fullScreen
    case compact

    var contentPadding: EdgeInsets {
        switch self {
        case .fullScreen:
            EdgeInsets(top: 80, leading: 24, bottom: 24, trailing: 24)
        case .compact:
            EdgeInsets(
                top: AirwaveLayout.compactPageTopPadding,
                leading: AirwaveLayout.compactPageHorizontalPadding,
                bottom: AirwaveLayout.compactPageBottomPadding,
                trailing: AirwaveLayout.compactPageHorizontalPadding
            )
        }
    }

    var maxContentWidth: CGFloat {
        switch self {
        case .fullScreen: 1000
        case .compact: AirwaveLayout.compactPageMaxWidth
        }
    }
}

struct AirwavePressedButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
