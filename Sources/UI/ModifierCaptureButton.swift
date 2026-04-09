import AppKit
import SwiftUI

struct ModifierCaptureButton: View {
    let valueText: String
    let isCapturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("[ \(valueText) ]")
                    .font(PulseUI.Typography.bodyStrong)
                    .pulsePrimaryText()
                Spacer()
                Text(isCapturing ? "录入中" : "点击录入")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                    .fill(PulseUI.ColorTokens.primaryFill.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                            .stroke(
                                isCapturing ? Color.accentColor : Color.primary.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
