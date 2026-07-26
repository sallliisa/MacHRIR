import SwiftUI

struct AirwavePageLayout<Content: View>: View {
    let mode: AirwavePageLayoutMode
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(mode.contentPadding)
            .frame(maxWidth: mode.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct AirwaveBlurScaleTransitionModifier: ViewModifier {
    let isIdentity: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isIdentity ? 1 : 0.97)
            .blur(radius: isIdentity ? 0 : 8)
            .opacity(isIdentity ? 1 : 0)
    }
}

extension AnyTransition {
    static var airwaveBlurScaleReveal: AnyTransition {
        .modifier(
            active: AirwaveBlurScaleTransitionModifier(isIdentity: false),
            identity: AirwaveBlurScaleTransitionModifier(isIdentity: true)
        )
    }
}

struct AirwaveEqualHeightColumnsLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let columnWidth = proposal.width.map { max(0, ($0 - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(max(1, subviews.count))) }
        let sizes = subviews.map { subview in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
        }
        let intrinsicWidth = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        let intrinsicHeight = sizes.map(\.height).max() ?? 0

        return CGSize(
            width: proposal.width ?? intrinsicWidth,
            height: proposal.height ?? intrinsicHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let columnWidth = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
            )
            x += columnWidth + spacing
        }
    }
}

struct AirwaveTopBar<Center: View, Trailing: View>: View {
    @ViewBuilder let center: () -> Center
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Image("AirwaveMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Airwave")
                Text("Airwave").font(.headline)
                Spacer(minLength: 12)
                trailing()
            }

            center()
        }
        .frame(height: 32)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }
}

struct AirwaveEmptyLibraryState: View {
    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(AirwaveLayout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(description)")
    }
}

struct AirwaveScrollEdgeFades: View {
    var bottomHeight: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: AirwavePalette.canvas, location: 0),
                    .init(color: AirwavePalette.canvas, location: 0.3),
                    .init(color: AirwavePalette.canvas.opacity(0.55), location: 0.58),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, AirwavePalette.canvas.opacity(0.94), AirwavePalette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottomHeight)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct AirwaveIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? AirwavePalette.canvas : (isHovering ? Color.primary : Color.secondary))
                .frame(width: 34, height: 34)
                .background { Circle().fill(buttonBackground) }
                .contentShape(Circle())
        }
        .buttonStyle(AirwavePressedButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }

    private var buttonBackground: Color {
        if isProminent {
            return Color.primary.opacity(isHovering ? 0.78 : 0.92)
        }
        return isHovering ? AirwavePalette.hover : .clear
    }
}

struct AirwaveSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AirwaveNavigationCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var showsWarning = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(AirwaveLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            showsWarning
                ? Color.orange.opacity(isHovering ? 0.18 : 0.10)
                : (isHovering ? AirwavePalette.hover : AirwavePalette.raised),
            in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(subtitle)")
        .accessibilityHint("Open \(title) settings")
    }
}
