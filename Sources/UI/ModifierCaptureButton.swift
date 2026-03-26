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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(isCapturing ? "录入中" : "点击录入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
