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
        let size = NSSize(width: 198, height: 38)
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
            context.duration = 0.10
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
        panel.hasShadow = false
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
            y: visibleFrame.minY + 22
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
                context.duration = 0.14
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
            return 0.62
        case .cancelled:
            return 0.08
        case .error:
            return 1.1
        case .idle, .listening:
            return 0.56
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
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
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
            return Color.primary.opacity(0.55)
        case .listening:
            return Color.primary.opacity(0.62)
        case .transcribing, .rewriting:
            return Color.primary.opacity(0.58)
        case .inserting:
            return Color.primary.opacity(0.60)
        case .cancelled, .error:
            return Color(red: 0.50, green: 0.22, blue: 0.22)
        }
    }

    private var listeningCapsule: some View {
        HStack(spacing: 8) {
            Text("语音输入")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.86))
                .lineLimit(1)

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.26))
                .frame(width: 0.8, height: 10)

            ListeningBars(level: normalizedListeningLevel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(HUDNativeMaterialCapsule())
    }

    private var thinkingCapsule: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(16, width * normalizedProgress)

            ZStack(alignment: .leading) {
                HUDNativeMaterialCapsule()

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.gray.opacity(0.28),
                                Color.gray.opacity(0.12)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .animation(.easeOut(duration: 0.18), value: normalizedProgress)

                HStack {
                    Spacer()
                    Text("思考中")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.80))
                    Spacer()
                }
            }
        }
        .frame(height: 26)
    }

    private var feedbackCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: phase.menuBarSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(phaseAccentColor)
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDNativeMaterialCapsule())
    }
}

private struct ListeningBars: View {
    let level: Double

    private var isActive: Bool {
        level > 0.035
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3.0) {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.78 : 0.28))
                    .frame(width: 1.8, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.10), value: level)
            }
        }
        .frame(width: 19, height: 10, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [2.0, 3.2, 2.8, 3.8]
        let gain: [CGFloat] = [2.5, 3.4, 3.0, 3.8]
        let normalized = CGFloat(max(0, min(1, level)))
        let eased = sqrt(normalized)
        return base[index] + (gain[index] * eased)
    }
}

private struct HUDNativeMaterialCapsule: View {
    var body: some View {
        ZStack {
            MacVisualEffectMaterialView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                state: .active
            )
            .clipShape(Capsule(style: .continuous))

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.26),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.6)

            Capsule(style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 0.55)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2)
    }
}

private struct MacVisualEffectMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
