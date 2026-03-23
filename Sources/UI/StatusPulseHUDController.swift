import AppKit
import SwiftUI

@MainActor
final class StatusPulseHUDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var previousPhase: SessionPhase = .idle

    func show(
        phase: SessionPhase,
        lane: InputLane,
        message: String,
        progress: Double,
        listeningLevel: Double
    ) {
        let size = NSSize(width: 184, height: 34)
        let panel = ensurePanel(size: size)
        let shouldSuppressBusyRefresh = phase.isBusyPhase && previousPhase.isBusyPhase && !panel.isVisible
        if shouldSuppressBusyRefresh {
            previousPhase = phase
            return
        }

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

        previousPhase = phase
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
        case .listening:
            return true
        case .idle, .transcribing, .rewriting, .inserting, .cancelled, .error:
            return false
        }
    }

    private func hideDelay(for phase: SessionPhase) -> TimeInterval {
        switch phase {
        case .transcribing, .rewriting, .inserting:
            return 0.24
        case .cancelled:
            return 0.46
        case .error:
            return 0.92
        case .idle, .listening:
            return 0.44
        }
    }
}

private extension SessionPhase {
    var isBusyPhase: Bool {
        switch self {
        case .transcribing, .rewriting, .inserting:
            return true
        case .idle, .listening, .cancelled, .error:
            return false
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
            switch phase {
            case .listening:
                listeningCapsule
            case .transcribing, .rewriting, .inserting:
                thinkingCapsule
            case .cancelled:
                cancelledCapsule
            case .error:
                errorCapsule
            case .idle:
                feedbackCapsule
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var normalizedListeningLevel: Double {
        max(0, min(1, listeningLevel))
    }

    private var normalizedProgress: Double {
        max(0, min(1, progress))
    }

    private var phaseAccentColor: Color {
        switch phase {
        case .idle:
            return Color.primary.opacity(0.56)
        case .listening:
            return Color.primary.opacity(0.62)
        case .transcribing, .rewriting:
            return Color.primary.opacity(0.58)
        case .inserting:
            return Color.primary.opacity(0.60)
        case .cancelled:
            return Color.primary.opacity(0.60)
        case .error:
            return Color(red: 0.56, green: 0.26, blue: 0.26)
        }
    }

    private var listeningCapsule: some View {
        statusSplitCapsule(title: "语音输入") {
            ListeningBars(level: normalizedListeningLevel)
        }
    }

    private var cancelledCapsule: some View {
        statusSplitCapsule(title: "已取消") {
            Circle()
                .stroke(Color.primary.opacity(0.42), lineWidth: 0.8)
                .frame(width: 11, height: 11)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.66))
                )
        }
    }

    private var errorCapsule: some View {
        statusSplitCapsule(title: "未完成") {
            Circle()
                .stroke(Color(red: 0.56, green: 0.26, blue: 0.26).opacity(0.66), lineWidth: 0.9)
                .frame(width: 11, height: 11)
                .overlay(
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color(red: 0.56, green: 0.26, blue: 0.26).opacity(0.76))
                )
        }
    }

    private var thinkingCapsule: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(20, width * normalizedProgress)

            ZStack(alignment: .leading) {
                HUDNativeMaterialCapsule()

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.gray.opacity(0.36),
                                Color.gray.opacity(0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .animation(.easeOut(duration: 0.18), value: normalizedProgress)

                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    Text("思考中")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineLimit(1)
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.24))
                        .frame(width: 0.7, height: 9)
                    ThinkingDots(progress: normalizedProgress)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(height: 22)
    }

    private var feedbackCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: phase.menuBarSymbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(phaseAccentColor)
            Text(message)
                .font(.system(size: 10.2, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.80))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDNativeMaterialCapsule())
    }

    @ViewBuilder
    private func statusSplitCapsule<Indicator: View>(
        title: String,
        @ViewBuilder indicator: () -> Indicator
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.84))
                .lineLimit(1)

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.24))
                .frame(width: 0.7, height: 9)

            indicator()
                .frame(width: 20, height: 10, alignment: .center)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .frame(width: 1.6, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.10), value: level)
            }
        }
        .frame(width: 19, height: 10, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [1.7, 2.7, 2.3, 3.2]
        let gain: [CGFloat] = [2.4, 3.3, 2.8, 3.7]
        let normalized = CGFloat(max(0, min(1, level)))
        let eased = sqrt(normalized)
        return base[index] + (gain[index] * eased)
    }
}

private struct ThinkingDots: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 3.0) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(dotOpacity(for: index)))
                    .frame(width: 3.8, height: 3.8)
            }
        }
        .frame(width: 22, height: 10, alignment: .center)
        .animation(.easeOut(duration: 0.16), value: progress)
    }

    private func dotOpacity(for index: Int) -> Double {
        let shifted = (progress * 5.8) + (Double(index) * 0.22)
        let wave = (sin(shifted * .pi) + 1) / 2
        return 0.25 + (wave * 0.60)
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
                            Color.gray.opacity(0.22),
                            Color.gray.opacity(0.14),
                            Color.gray.opacity(0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)

            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 0.55)

            Capsule(style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 4, x: 0, y: 1.5)
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
