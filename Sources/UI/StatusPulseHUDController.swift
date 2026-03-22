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
        progress: Double,
        listeningLevel: Double
    ) {
        let size = NSSize(width: 236, height: 44)
        let panel = ensurePanel(size: size)
        panel.contentView = NSHostingView(
            rootView: StatusPulseHUDView(
                phase: phase,
                lane: lane,
                message: message,
                progress: progress,
                listeningLevel: listeningLevel
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
            y: visibleFrame.minY + 30
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
    let listeningLevel: Double

    var body: some View {
        Group {
            if phase == .listening {
                listeningCapsule
            } else if isThinkingPhase {
                thinkingCapsule
            } else {
                feedbackCapsule
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var normalizedListeningLevel: Double {
        max(0, min(1, listeningLevel))
    }

    private var normalizedProgress: Double {
        max(0, min(1, progress))
    }

    private var isThinkingPhase: Bool {
        switch phase {
        case .transcribing, .rewriting, .inserting:
            return true
        case .idle, .listening, .cancelled, .error:
            return false
        }
    }

    private var phaseAccentColor: Color {
        switch phase {
        case .idle:
            return Color.black.opacity(0.56)
        case .listening:
            return Color.black.opacity(0.64)
        case .transcribing:
            return Color.black.opacity(0.60)
        case .rewriting:
            return Color.black.opacity(0.60)
        case .inserting:
            return Color.black.opacity(0.64)
        case .cancelled, .error:
            return Color(red: 0.53, green: 0.27, blue: 0.27)
        }
    }

    private var listeningCapsule: some View {
        HStack(spacing: 10) {
            Text("语音输入")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.78))
                .lineLimit(1)

            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.16))
                .frame(width: 0.9, height: 13)

            ListeningBars(level: normalizedListeningLevel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(LiquidCapsuleBackground())
    }

    private var thinkingCapsule: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(24, width * normalizedProgress)

            ZStack(alignment: .leading) {
                LiquidCapsuleBackground()

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.24),
                                Color.black.opacity(0.16)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .animation(.easeOut(duration: 0.24), value: normalizedProgress)

                HStack {
                    Spacer()
                    Text("思考中")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.72))
                    Spacer()
                }
            }
        }
        .frame(height: 32)
    }

    private var feedbackCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: phase.menuBarSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(phaseAccentColor)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.74))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiquidCapsuleBackground())
    }
}

private struct ListeningBars: View {
    let level: Double

    private var isActive: Bool {
        level > 0.03
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3.6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(isActive ? 0.68 : 0.24))
                    .frame(width: 2.1, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(width: 22, height: 14, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [2.8, 4.2, 3.5, 5.0]
        let gain: [CGFloat] = [3.8, 4.8, 4.2, 5.8]
        let normalized = CGFloat(max(0, min(1, level)))
        let eased = sqrt(normalized)
        return base[index] + (gain[index] * eased)
    }
}

private struct LiquidCapsuleBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.97, blue: 0.98).opacity(0.94),
                        Color(red: 0.86, green: 0.88, blue: 0.90).opacity(0.84)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.58),
                                Color.white.opacity(0.14),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.64), lineWidth: 0.8)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
    }
}
