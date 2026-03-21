import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        Image(systemName: sessionStore.phase.menuBarSymbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(menuBarColor)
            .help("PulseType: \(sessionStore.phase.title)")
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
}
