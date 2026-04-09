import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: sessionStore.phase.menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)

            if sessionStore.phase == .listening {
                ListeningLevelPips(level: sessionStore.listeningLevel)
                    .transition(.opacity)
            } else if sessionStore.phase.isBusyPhase {
                BusyPhaseDots(tint: menuBarColor)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: sessionStore.phase)
        .help(helpText)
    }

    private var menuBarColor: Color {
        switch sessionStore.phase {
        case .idle:
            return PulseUI.ColorTokens.textSecondary
        case .listening:
            return PulseUI.ColorTokens.glow
        case .transcribing:
            return PulseUI.ColorTokens.glow.opacity(0.82)
        case .rewriting:
            return PulseUI.ColorTokens.textSecondary
        case .inserting:
            return PulseUI.ColorTokens.success
        case .cancelled:
            return PulseUI.ColorTokens.danger
        case .error:
            return PulseUI.ColorTokens.danger
        }
    }

    private var helpText: String {
        if sessionStore.phase == .listening {
            return "PulseType：聆听中"
        }
        if sessionStore.phase.isBusyPhase {
            return "PulseType：\(sessionStore.phase.title)"
        }
        return "PulseType：\(sessionStore.phase.title)"
    }
}

private struct ListeningLevelPips: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(PulseUI.ColorTokens.glow.opacity(opacity(for: index)))
                    .frame(width: 2.5, height: barHeight(for: index))
            }
        }
        .frame(width: 16, height: 13, alignment: .bottom)
        .animation(.linear(duration: 0.06), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(max(0, min(1, level)))
        let floorHeights: [CGFloat] = [3.5, 6, 4.5]
        let gains: [CGFloat] = [6, 6.5, 7]
        return floorHeights[index] + (normalized * gains[index])
    }

    private func opacity(for index: Int) -> Double {
        let normalized = max(0, min(1, level))
        let baseline: [Double] = [0.35, 0.45, 0.35]
        return min(1, baseline[index] + (normalized * 0.6))
    }
}

private struct BusyPhaseDots: View {
    let tint: Color
    @State private var activeIndex: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(activeIndex == index ? 1 : 0.35))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 15, height: 13, alignment: .center)
        .onAppear {
            activeIndex = 0
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                activeIndex = (activeIndex + 1) % 3
            }
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
