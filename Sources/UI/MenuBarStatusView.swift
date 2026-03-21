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
            }
        }
        .animation(.easeOut(duration: 0.12), value: sessionStore.phase)
        .help(helpText)
    }

    private var menuBarColor: Color {
        switch sessionStore.phase {
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
        case .cancelled:
            return .red
        case .error:
            return .red
        }
    }

    private var helpText: String {
        if sessionStore.phase == .listening {
            let levelPercent = Int((sessionStore.listeningLevel * 100).rounded())
            return "PulseType: Listening (\(levelPercent)%)"
        }
        return "PulseType: \(sessionStore.phase.title)"
    }
}

private struct ListeningLevelPips: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.blue.opacity(opacity(for: index)))
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
