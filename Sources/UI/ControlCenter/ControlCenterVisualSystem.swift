import AppKit
import SwiftUI

enum PulseUI {
    struct TypeSpec {
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: Font.Weight
        let design: Font.Design
    }

    enum Spacing {
        static let pageHorizontal: CGFloat = 24
        static let pageVertical: CGFloat = 20
        static let section: CGFloat = 16
        static let cardPadding: CGFloat = 14
        static let compactCardPadding: CGFloat = 10
    }

    enum Radius {
        static let header: CGFloat = 14
        static let sectionGroup: CGFloat = 12
        static let card: CGFloat = 10
        static let compactCard: CGFloat = 8
        static let listRow: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let heroSpec = TypeSpec(size: 21, lineHeight: 27, weight: .semibold, design: .serif)
        static let sectionSpec = TypeSpec(size: 15, lineHeight: 20, weight: .semibold, design: .default)
        static let bodySpec = TypeSpec(size: 13.5, lineHeight: 19, weight: .regular, design: .default)
        static let bodyMediumSpec = TypeSpec(size: 13.5, lineHeight: 19, weight: .medium, design: .default)
        static let captionSpec = TypeSpec(size: 12, lineHeight: 17, weight: .regular, design: .default)
        static let captionStrongSpec = TypeSpec(size: 12, lineHeight: 17, weight: .semibold, design: .default)
        static let tinySpec = TypeSpec(size: 11, lineHeight: 15, weight: .regular, design: .default)
        static let metricSpec = TypeSpec(size: 17, lineHeight: 22, weight: .semibold, design: .default)

        static let pageTitle = Font.system(
            size: heroSpec.size,
            weight: heroSpec.weight,
            design: heroSpec.design
        )
        static let sectionTitle = Font.system(
            size: sectionSpec.size,
            weight: sectionSpec.weight,
            design: sectionSpec.design
        )
        static let body = Font.system(
            size: bodySpec.size,
            weight: bodySpec.weight,
            design: bodySpec.design
        )
        static let bodyStrong = Font.system(
            size: bodyMediumSpec.size,
            weight: bodyMediumSpec.weight,
            design: bodyMediumSpec.design
        )
        static let caption = Font.system(size: captionSpec.size, weight: captionSpec.weight, design: captionSpec.design)
        static let captionStrong = Font.system(size: captionStrongSpec.size, weight: captionStrongSpec.weight, design: captionStrongSpec.design)
        static let value = Font.system(
            size: metricSpec.size,
            weight: metricSpec.weight,
            design: metricSpec.design
        )
        static let monospacedMeta = Font.system(size: tinySpec.size, weight: tinySpec.weight, design: .monospaced)

        static let pageTitleLineSpacing: CGFloat = heroSpec.lineHeight - heroSpec.size
        static let bodyLineSpacing: CGFloat = bodySpec.lineHeight - bodySpec.size
        static let captionLineSpacing: CGFloat = captionSpec.lineHeight - captionSpec.size
        static let tinyLineSpacing: CGFloat = tinySpec.lineHeight - tinySpec.size
    }

    enum ColorTokens {
        static let textPrimary = Color.primary
        static let textSecondary = Color.primary.opacity(0.66)
        static let textTertiary = Color.primary.opacity(0.52)
        static let success = Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.42, alpha: 1))
        static let warning = Color(nsColor: NSColor(calibratedRed: 0.76, green: 0.49, blue: 0.15, alpha: 1))
        static let danger = Color(nsColor: NSColor(calibratedRed: 0.72, green: 0.29, blue: 0.27, alpha: 1))

        static let backgroundTop = Color(
            nsColor: NSColor(calibratedRed: 0.969, green: 0.962, blue: 0.945, alpha: 1)
        )
        static let backgroundBottom = Color(
            nsColor: NSColor(calibratedRed: 0.945, green: 0.933, blue: 0.907, alpha: 1)
        )
        static let glow = Color(
            nsColor: NSColor(calibratedRed: 0.788, green: 0.392, blue: 0.258, alpha: 1)
        )
        static let primaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.988, green: 0.983, blue: 0.968, alpha: 1)
        )
        static let secondaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.964, green: 0.953, blue: 0.925, alpha: 1)
        )
        static let stroke = Color.black.opacity(0.082)
        static let glassStroke = Color.white.opacity(0.52)
        static let glassShadow = Color.black.opacity(0.062)
        static let softShadow = Color.black.opacity(0.052)
    }
}

struct ControlCenterDetailBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    PulseUI.ColorTokens.backgroundTop,
                    PulseUI.ColorTokens.backgroundBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    PulseUI.ColorTokens.glow.opacity(0.12),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 360
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.48),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 60,
                endRadius: 420
            )
        }
    }
}

private enum ControlCenterSurfaceKind {
    case primary
    case secondary
    case listRow
}

private struct ControlCenterSurfaceStyle: ViewModifier {
    let kind: ControlCenterSurfaceKind
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityShowBorders) private var showBorders

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            let fill = kind == .secondary ? PulseUI.ColorTokens.secondaryFill.opacity(0.88) : Color.white.opacity(0.78)
            content
                .background(
                    shape
                        .fill(reduceTransparency ? fill : Color.clear)
                )
                .modifier(
                    GlassLayerModifier(enabled: !reduceTransparency, cornerRadius: cornerRadius)
                )
                .overlay(
                    shape
                        .stroke(
                            showBorders ? Color.primary.opacity(0.34) : PulseUI.ColorTokens.glassStroke,
                            lineWidth: showBorders ? 1.2 : 1
                        )
                )
                .shadow(color: PulseUI.ColorTokens.glassShadow, radius: 9, x: 0, y: 4)
        } else {
            let fill = kind == .secondary ? PulseUI.ColorTokens.secondaryFill : PulseUI.ColorTokens.primaryFill
            let shadowRadius: CGFloat = kind == .listRow ? 6 : 10
            content
                .background(
                    shape
                        .fill(fill)
                )
                .overlay(
                    shape
                        .stroke(
                            showBorders ? Color.primary.opacity(0.34) : PulseUI.ColorTokens.stroke,
                            lineWidth: showBorders ? 1.2 : 1
                        )
                )
                .shadow(color: PulseUI.ColorTokens.softShadow, radius: shadowRadius, x: 0, y: 4)
        }
    }
}

@available(macOS 26, *)
private struct GlassLayerModifier: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

extension View {
    func pulseCard(cornerRadius: CGFloat) -> some View {
        modifier(ControlCenterSurfaceStyle(kind: .primary, cornerRadius: cornerRadius))
    }

    func controlCenterSectionGroup(cornerRadius: CGFloat = 16) -> some View {
        modifier(ControlCenterSurfaceStyle(kind: .primary, cornerRadius: cornerRadius))
    }

    func controlCenterInsetPanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(ControlCenterSurfaceStyle(kind: .secondary, cornerRadius: cornerRadius))
    }

    func controlCenterListRow(cornerRadius: CGFloat = 14) -> some View {
        modifier(ControlCenterSurfaceStyle(kind: .listRow, cornerRadius: cornerRadius))
    }

    func pulsePrimaryText() -> some View {
        foregroundStyle(PulseUI.ColorTokens.textPrimary)
    }

    func pulseSecondaryText() -> some View {
        foregroundStyle(PulseUI.ColorTokens.textSecondary)
    }

    func pulseTertiaryText() -> some View {
        foregroundStyle(PulseUI.ColorTokens.textTertiary)
    }

    @ViewBuilder
    func controlCenterPrimaryActionButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func controlCenterSecondaryActionButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
