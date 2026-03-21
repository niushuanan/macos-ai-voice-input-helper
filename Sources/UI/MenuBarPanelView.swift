import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusCard(sessionStore: model.sessionStore)

            interactionSkeletonSection

            laneSection

            quickFlowSection

            utilitySection
        }
        .padding(18)
        .frame(width: 360)
    }

    private var interactionSkeletonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap-Tap Skeleton")
                .font(.headline)

            Text("Wake: Control + Option + Space")
                .font(.caption)
            Text("Stop: tap the same combo while listening")
                .font(.caption)
            Text("Cancel: Control + Option + Escape")
                .font(.caption)
            Text("Rewrite lane: hold Option on wake with active selection")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var laneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interaction Lanes")
                .font(.headline)

            LaneCard(
                title: model.sessionStore.activeLane == .directDictation ? "Direct Dictation Active" : "Direct Dictation",
                subtitle: "Fresh text into the focused app",
                shortcut: model.hotkeyCoordinator.wakeShortcut.trigger,
                accent: .blue
            )

            LaneCard(
                title: "Selection Rewrite",
                subtitle: "Talk over highlighted text without leaving the keyboard",
                shortcut: model.hotkeyCoordinator.rewriteModifierHint.trigger,
                accent: .orange
            )
        }
    }

    private var quickFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Flow Drill")
                .font(.headline)

            HStack {
                Button("Wake Dictate") {
                    model.interactionCoordinator.handleWakeInput(context: .dictation)
                }
                .disabled(!canStartSession)

                Button("Wake Rewrite") {
                    model.interactionCoordinator.handleWakeInput(
                        context: WakeInvocationContext(
                            rewriteModifierHeld: true,
                            selectionAvailable: true
                        )
                    )
                }
                .disabled(!canStartSession)

                Button("Stop") {
                    model.interactionCoordinator.handleStopInput()
                }
                .disabled(model.sessionStore.phase != .listening)
            }

            HStack {
                Button("Rewrite") {
                    model.sessionStore.markRewriting()
                }
                .disabled(model.sessionStore.phase != .transcribing)

                Button("Insert") {
                    model.sessionStore.markInserting()
                }
                .disabled(!canInsert)

                Button("Finish") {
                    model.interactionCoordinator.handleCompleteInput()
                }
                .disabled(model.sessionStore.phase != .inserting)
            }

            HStack {
                Button("Cancel", role: .destructive) {
                    model.interactionCoordinator.handleCancelInput()
                }
                .disabled(model.sessionStore.phase == .idle)

                Button("Simulate Error") {
                    model.sessionStore.fail(message: "A provider or permissions issue blocked the session.")
                }

                Button("Reset") {
                    model.interactionCoordinator.handleResetInput()
                }
            }
        }
    }

    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("Provider and Storage")
                .font(.headline)

            InfoRow(title: "Speech provider", value: model.providerSettingsStore.selectedProviderName)
            InfoRow(title: "Model", value: model.providerSettingsStore.modelName)
            InfoRow(title: "Insertion path", value: model.textOutputCoordinator.insertionStrategy)
            InfoRow(title: "History root", value: model.localStore.rootDirectory.path)

            HStack {
                SettingsLink {
                    Label("Settings...", systemImage: "gearshape")
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 4)
        }
    }

    private var canStartSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private var canInsert: Bool {
        model.sessionStore.phase == .rewriting || model.sessionStore.phase == .transcribing
    }
}

private struct StatusCard: View {
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(sessionStore.phase.title, systemImage: sessionStore.phase.menuBarSymbol)
                    .font(.headline)
                    .foregroundStyle(sessionStore.phase.tintColor)

                Spacer()

                Text(sessionStore.activeLane.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(sessionStore.activeLane.badgeColor.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(sessionStore.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if sessionStore.phase == .listening {
                ListeningLevelStrip(level: sessionStore.listeningLevel)
            }

            if let clip = sessionStore.pendingClip {
                Text("Pending audio: \(clip.displaySummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorMessage = sessionStore.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sessionStore.phase.tintColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ListeningLevelStrip: View {
    let level: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input level")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.blue.opacity(0.15))

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.55), Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.06), value: level)
        }
    }
}

private struct LaneCard: View {
    let title: String
    let subtitle: String
    let shortcut: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(shortcut)
                .font(.caption.monospaced())
                .foregroundStyle(accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private extension SessionPhase {
    var tintColor: Color {
        switch self {
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

private extension InputLane {
    var badgeColor: Color {
        switch self {
        case .directDictation:
            return .blue
        case .selectionRewrite:
            return .orange
        }
    }
}
