import AppKit
import SwiftUI

@MainActor
final class StatusPulseHUDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(
        phase: SessionPhase,
        lane: InputLane,
        message: String,
        progress: Double
    ) {
        let size = NSSize(width: 430, height: 112)
        let panel = ensurePanel(size: size)
        panel.contentView = NSHostingView(
            rootView: StatusPulseHUDView(
                phase: phase,
                lane: lane,
                message: message,
                progress: progress
            )
        )

        position(panel: panel, size: size)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        scheduleHide(for: phase)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func position(panel: NSPanel, size: NSSize) {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = targetScreen?.visibleFrame else {
            return
        }

        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 34
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func scheduleHide(for phase: SessionPhase) {
        hideWorkItem?.cancel()

        if shouldKeepVisible(for: phase) {
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else {
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }

        hideWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + hideDelay(for: phase),
            execute: work
        )
    }

    private func shouldKeepVisible(for phase: SessionPhase) -> Bool {
        switch phase {
        case .listening, .transcribing, .rewriting, .inserting:
            return true
        case .idle, .cancelled, .error:
            return false
        }
    }

    private func hideDelay(for phase: SessionPhase) -> TimeInterval {
        switch phase {
        case .transcribing, .rewriting, .inserting:
            return 0.8
        case .cancelled:
            return 0.08
        case .error:
            return 1.4
        case .idle, .listening:
            return 0.72
        }
    }
}

private struct StatusPulseHUDView: View {
    let phase: SessionPhase
    let lane: InputLane
    let message: String
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: phase.menuBarSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(phaseColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(phase.title) · \(lane.title)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule(style: .continuous)
                                .fill(index <= currentStageIndex ? phaseColor : Color.secondary.opacity(0.22))
                                .frame(height: 7)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(Array(stageLabels.enumerated()), id: \.offset) { index, label in
                            Text(label)
                                .font(.system(size: 10, weight: index == currentStageIndex ? .semibold : .regular))
                                .foregroundStyle(index <= currentStageIndex ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(phaseColor.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var normalizedProgress: Double {
        max(0, min(1, progress))
    }

    private var currentStageIndex: Int {
        switch phase {
        case .listening:
            return 0
        case .transcribing:
            return 1
        case .rewriting:
            return 2
        case .inserting, .idle:
            return 3
        case .cancelled, .error:
            return min(3, max(0, Int((normalizedProgress * 4).rounded(.down))))
        }
    }

    private var stageLabels: [String] {
        ["聆听", "转写", "文本处理", "写入"]
    }

    private var phaseColor: Color {
        switch phase {
        case .idle:
            return .secondary
        case .listening:
            return .blue
        case .transcribing:
            return .purple
        case .rewriting:
            return .orange
        case .inserting:
            return .green
        case .cancelled, .error:
            return .red
        }
    }
}
