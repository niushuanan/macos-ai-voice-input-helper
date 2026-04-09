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
        static let pageHorizontal: CGFloat = 22
        static let pageVertical: CGFloat = 20
        static let section: CGFloat = 14
        static let cardPadding: CGFloat = 12
        static let compactCardPadding: CGFloat = 9
    }

    enum Radius {
        static let header: CGFloat = 16
        static let sectionGroup: CGFloat = 14
        static let card: CGFloat = 11
        static let compactCard: CGFloat = 9
        static let listRow: CGFloat = 12
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let heroSpec = TypeSpec(size: 24, lineHeight: 30, weight: .bold, design: .rounded)
        static let sectionSpec = TypeSpec(size: 15.5, lineHeight: 20, weight: .semibold, design: .rounded)
        static let bodySpec = TypeSpec(size: 13.5, lineHeight: 18, weight: .regular, design: .default)
        static let bodyMediumSpec = TypeSpec(size: 13.5, lineHeight: 18, weight: .medium, design: .default)
        static let captionSpec = TypeSpec(size: 12, lineHeight: 16, weight: .regular, design: .default)
        static let captionStrongSpec = TypeSpec(size: 12, lineHeight: 16, weight: .semibold, design: .default)
        static let tinySpec = TypeSpec(size: 11, lineHeight: 14, weight: .regular, design: .default)
        static let metricSpec = TypeSpec(size: 19, lineHeight: 24, weight: .semibold, design: .rounded)

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
    }

    enum ColorTokens {
        static let textPrimary = Color.primary
        static let textSecondary = Color.primary.opacity(0.70)
        static let textTertiary = Color.primary.opacity(0.52)
        static let success = Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.64, blue: 0.42, alpha: 1))
        static let warning = Color(nsColor: NSColor(calibratedRed: 0.78, green: 0.53, blue: 0.12, alpha: 1))
        static let danger = Color(nsColor: NSColor(calibratedRed: 0.83, green: 0.30, blue: 0.30, alpha: 1))

        static let backgroundTop = Color(
            nsColor: NSColor(calibratedRed: 0.961, green: 0.957, blue: 0.941, alpha: 1)
        )
        static let backgroundBottom = Color(
            nsColor: NSColor(calibratedRed: 0.947, green: 0.958, blue: 0.976, alpha: 1)
        )
        static let glow = Color(
            nsColor: NSColor(calibratedRed: 0.322, green: 0.518, blue: 0.836, alpha: 1)
        )
        static let primaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.975, green: 0.975, blue: 0.971, alpha: 1)
        )
        static let secondaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.957, green: 0.962, blue: 0.972, alpha: 1)
        )
        static let stroke = Color.black.opacity(0.072)
        static let glassStroke = Color.white.opacity(0.34)
        static let glassShadow = Color.black.opacity(0.058)
        static let softShadow = Color.black.opacity(0.035)
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

            Circle()
                .fill(PulseUI.ColorTokens.glow.opacity(0.24))
                .frame(width: 500, height: 500)
                .offset(x: 240, y: -260)
                .blur(radius: 54)

            Circle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 420, height: 420)
                .offset(x: -280, y: 220)
                .blur(radius: 66)
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

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content
                .background(
                    shape
                        .fill(kind == .secondary ? PulseUI.ColorTokens.secondaryFill.opacity(0.18) : Color.white.opacity(0.16))
                )
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(
                    shape
                        .stroke(PulseUI.ColorTokens.glassStroke, lineWidth: 1)
                )
                .shadow(color: PulseUI.ColorTokens.glassShadow, radius: 8, x: 0, y: 3)
        } else {
            let fill = kind == .secondary ? PulseUI.ColorTokens.secondaryFill : PulseUI.ColorTokens.primaryFill
            let shadowRadius: CGFloat = kind == .listRow ? 8 : 12
            content
                .background(
                    shape
                        .fill(fill)
                )
                .overlay(
                    shape
                        .stroke(PulseUI.ColorTokens.stroke, lineWidth: 1)
                )
                .shadow(color: PulseUI.ColorTokens.softShadow, radius: shadowRadius, x: 0, y: 4)
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
