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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "麦克风"
        case .accessibility:
            return "辅助功能"
        }
    }
}

struct PermissionSnapshot: Equatable {
    var microphone: PermissionState
    var accessibility: PermissionState

    static let initial = PermissionSnapshot(
        microphone: .notRequested,
        accessibility: .notRequested
    )

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            return microphone
        case .accessibility:
            return accessibility
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
    private let microphoneStateResolver: (() -> PermissionState)?
    private let accessibilityStateResolver: (() -> PermissionState)?

    init(
        defaults: UserDefaults = .standard,
        microphoneStateResolver: (() -> PermissionState)? = nil,
        accessibilityStateResolver: (() -> PermissionState)? = nil
    ) {
        self.defaults = defaults
        self.microphoneStateResolver = microphoneStateResolver
        self.accessibilityStateResolver = accessibilityStateResolver
    }

    func refreshStatuses() {
        snapshot = PermissionSnapshot(
            microphone: microphoneState(),
            accessibility: accessibilityState()
        )
    }

    func requestAccess(for kind: PermissionKind) {
        switch kind {
        case .microphone:
            requestMicrophoneAccess()
        case .accessibility:
            requestAccessibilityAccess()
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        let urlString: String
        switch kind {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
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
        snapshot.accessibility = .pending
        defaults.set(true, forKey: didPromptAccessibilityKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatuses()
        }
    }

    private func microphoneState() -> PermissionState {
        if let microphoneStateResolver {
            return microphoneStateResolver()
        }

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
        if let accessibilityStateResolver {
            return accessibilityStateResolver()
        }

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
                return "已允许，可直接开始语音会话。"
            case .notRequested:
                return "未允许，语音会话暂时无法开始。"
            case .pending:
                return "系统弹窗处理中，请确认麦克风权限。"
            case .denied:
                return "已拒绝，PulseType 无法录音。"
            case .notRequired:
                return "不需要。"
            }
        case .accessibility:
            switch snapshot.accessibility {
            case .granted:
                return "已允许，可进行跨应用改写与直写。"
            case .notRequested:
                return "普通听写可运行，但改写与稳定直写建议开启。"
            case .pending:
                return "权限向导已打开，请在系统设置里完成。"
            case .denied:
                return "已拒绝，选区改写与 AX 直写不可用。"
            case .notRequired:
                return "不需要。"
            }
        }
    }

    private func guidanceText(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "先点“请求”，如果被拒绝，请到 系统设置 > 隐私与安全性 > 麦克风 开启 PulseType。"
        case .accessibility:
            return "先点“请求”，再到 系统设置 > 隐私与安全性 > 辅助功能 开启 PulseType。"
        }
    }
}
