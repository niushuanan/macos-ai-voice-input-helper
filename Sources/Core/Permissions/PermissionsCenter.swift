import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation

enum PermissionState: String {
    case notRequested
    case pending
    case granted
    case denied
    case notRequired
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case globalHotkeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .globalHotkeys:
            return "Global Hotkeys"
        }
    }
}

struct PermissionSnapshot: Equatable {
    var microphone: PermissionState
    var accessibility: PermissionState
    var globalHotkeys: PermissionState

    static let initial = PermissionSnapshot(
        microphone: .notRequested,
        accessibility: .notRequested,
        globalHotkeys: .notRequired
    )

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            return microphone
        case .accessibility:
            return accessibility
        case .globalHotkeys:
            return globalHotkeys
        }
    }

    var canStartVoiceSession: Bool {
        microphone == .granted
    }

    var hasBlockingIssue: Bool {
        !canStartVoiceSession
    }
}

struct PermissionPresentation: Identifiable {
    let id: PermissionKind
    let title: String
    let state: PermissionState
    let detail: String
    let guidance: String
}

@MainActor
final class PermissionsCenter: ObservableObject {
    @Published private(set) var snapshot: PermissionSnapshot = .initial

    private let defaults: UserDefaults
    private let didPromptAccessibilityKey = "permissions.didPromptAccessibility"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refreshStatuses() {
        snapshot = PermissionSnapshot(
            microphone: microphoneState(),
            accessibility: accessibilityState(),
            globalHotkeys: .notRequired
        )
    }

    func requestAccess(for kind: PermissionKind) {
        switch kind {
        case .microphone:
            requestMicrophoneAccess()
        case .accessibility:
            requestAccessibilityAccess()
        case .globalHotkeys:
            break
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        let urlString: String
        switch kind {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .globalHotkeys:
            urlString = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }

        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func presentationItems() -> [PermissionPresentation] {
        PermissionKind.allCases.map { kind in
            PermissionPresentation(
                id: kind,
                title: kind.title,
                state: snapshot.state(for: kind),
                detail: detailText(for: kind),
                guidance: guidanceText(for: kind)
            )
        }
    }

    private func requestMicrophoneAccess() {
        snapshot.microphone = .pending
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatuses()
            }
        }
    }

    private func requestAccessibilityAccess() {
        defaults.set(true, forKey: didPromptAccessibilityKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshStatuses()
    }

    private func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notRequested
        case .restricted:
            return .denied
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .denied
        }
    }

    private func accessibilityState() -> PermissionState {
        if AXIsProcessTrusted() {
            return .granted
        }
        return defaults.bool(forKey: didPromptAccessibilityKey) ? .denied : .notRequested
    }

    private func detailText(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            switch snapshot.microphone {
            case .granted:
                return "Ready. Voice sessions can start immediately."
            case .notRequested:
                return "Missing. Voice sessions cannot start until microphone access is granted."
            case .pending:
                return "System prompt is in progress. Confirm microphone access to continue."
            case .denied:
                return "Denied. PulseType cannot capture speech."
            case .notRequired:
                return "Not required."
            }
        case .accessibility:
            switch snapshot.accessibility {
            case .granted:
                return "Ready. Cross-app selection rewrite and direct insertion are available."
            case .notRequested:
                return "Optional for dictation fallback, required for stable rewrite and direct insertion."
            case .pending:
                return "Authorization request has been opened. Finish it in System Settings."
            case .denied:
                return "Denied. Selection rewrite and AX insertion are not available."
            case .notRequired:
                return "Not required."
            }
        case .globalHotkeys:
            return "No extra permission is required for Carbon-level global hotkeys."
        }
    }

    private func guidanceText(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Tap Request first. If denied, open System Settings > Privacy & Security > Microphone and enable PulseType."
        case .accessibility:
            return "Tap Request first. Then enable PulseType in System Settings > Privacy & Security > Accessibility."
        case .globalHotkeys:
            return "If shortcuts conflict with macOS defaults, change them in PulseType settings or System Settings > Keyboard > Keyboard Shortcuts."
        }
    }
}
