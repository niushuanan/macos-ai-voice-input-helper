import AppKit
import SwiftUI

enum PulseUI {
    enum Spacing {
        static let pageHorizontal: CGFloat = 24
        static let pageVertical: CGFloat = 22
        static let section: CGFloat = 16
        static let cardPadding: CGFloat = 14
        static let compactCardPadding: CGFloat = 10
    }

    enum Radius {
        static let header: CGFloat = 18
        static let sectionGroup: CGFloat = 16
        static let card: CGFloat = 12
        static let compactCard: CGFloat = 10
        static let listRow: CGFloat = 14
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let pageTitle = Font.system(size: 31, weight: .bold, design: .rounded)
        static let sectionTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 14, weight: .regular, design: .default)
        static let bodyStrong = Font.system(size: 14, weight: .medium, design: .default)
        static let caption = Font.system(size: 12, weight: .regular, design: .default)
        static let captionStrong = Font.system(size: 12, weight: .semibold, design: .default)
        static let value = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let monospacedMeta = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    }

    enum ColorTokens {
        static let textPrimary = Color.primary
        static let textSecondary = Color.primary.opacity(0.72)
        static let textTertiary = Color.primary.opacity(0.56)
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red

        static let backgroundTop = Color(
            nsColor: NSColor(calibratedRed: 0.927, green: 0.945, blue: 0.973, alpha: 1)
        )
        static let backgroundBottom = Color(
            nsColor: NSColor(calibratedRed: 0.968, green: 0.978, blue: 0.993, alpha: 1)
        )
        static let glow = Color(
            nsColor: NSColor(calibratedRed: 0.347, green: 0.557, blue: 0.875, alpha: 1)
        )
        static let primaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.951, green: 0.959, blue: 0.974, alpha: 1)
        )
        static let secondaryFill = Color(
            nsColor: NSColor(calibratedRed: 0.966, green: 0.972, blue: 0.984, alpha: 1)
        )
        static let stroke = Color.black.opacity(0.068)
        static let glassStroke = Color.white.opacity(0.37)
        static let glassShadow = Color.black.opacity(0.065)
        static let softShadow = Color.black.opacity(0.038)
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
