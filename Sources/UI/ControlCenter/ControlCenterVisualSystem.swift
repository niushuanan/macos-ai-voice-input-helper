import AppKit
import SwiftUI

private enum ControlCenterPalette {
    static let primaryFill = Color(
        nsColor: NSColor(calibratedRed: 0.955, green: 0.961, blue: 0.976, alpha: 1)
    )
    static let secondaryFill = Color(
        nsColor: NSColor(calibratedRed: 0.969, green: 0.974, blue: 0.986, alpha: 1)
    )
    static let stroke = Color.black.opacity(0.065)
    static let glassStroke = Color.white.opacity(0.35)
    static let glassShadow = Color.black.opacity(0.06)
    static let glow = Color(
        nsColor: NSColor(calibratedRed: 0.419, green: 0.619, blue: 0.925, alpha: 1)
    )
}

struct ControlCenterDetailBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(
                        nsColor: NSColor(calibratedRed: 0.932, green: 0.956, blue: 0.987, alpha: 1)
                    ),
                    Color(
                        nsColor: NSColor(calibratedRed: 0.972, green: 0.985, blue: 0.997, alpha: 1)
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(ControlCenterPalette.glow.opacity(0.25))
                .frame(width: 420, height: 420)
                .offset(x: 220, y: -240)
                .blur(radius: 42)

            Circle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 360, height: 360)
                .offset(x: -260, y: 210)
                .blur(radius: 58)
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
                        .fill(kind == .secondary ? ControlCenterPalette.secondaryFill.opacity(0.18) : Color.white.opacity(0.16))
                )
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(
                    shape
                        .stroke(ControlCenterPalette.glassStroke, lineWidth: 1)
                )
                .shadow(color: ControlCenterPalette.glassShadow, radius: 8, x: 0, y: 3)
        } else {
            let fill = kind == .secondary ? ControlCenterPalette.secondaryFill : ControlCenterPalette.primaryFill
            let shadowRadius: CGFloat = kind == .listRow ? 7 : 11
            content
                .background(
                    shape
                        .fill(fill)
                )
                .overlay(
                    shape
                        .stroke(ControlCenterPalette.stroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: shadowRadius, x: 0, y: 3)
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
