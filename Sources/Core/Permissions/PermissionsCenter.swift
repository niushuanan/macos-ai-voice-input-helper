import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation
import Security

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

struct PermissionRuntimeDiagnostics: Equatable {
    let bundleIdentifier: String
    let bundlePath: String
    let executablePath: String
    let signatureSummary: String
    let checkedAt: Date

    static func current(bundle: Bundle = .main, now: Date = Date()) -> PermissionRuntimeDiagnostics {
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
        let bundlePath = bundle.bundlePath
        let executablePath = bundle.executablePath ?? bundle.bundlePath
        return PermissionRuntimeDiagnostics(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            executablePath: executablePath,
            signatureSummary: signatureSummary(forExecutablePath: executablePath),
            checkedAt: now
        )
    }

    private static func signatureSummary(forExecutablePath executablePath: String) -> String {
        let executableURL = URL(fileURLWithPath: executablePath)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return "签名信息不可用"
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard
            infoStatus == errSecSuccess,
            let dictionary = information as? [String: Any]
        else {
            return "签名信息不可用"
        }

        let teamIdentifier = (
            dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        ) ?? (dictionary["teamid"] as? String)
        let source = (
            dictionary[kSecCodeInfoSource as String] as? String
        ) ?? (dictionary["source"] as? String)

        if let teamIdentifier, !teamIdentifier.isEmpty {
            return "已签名 · TeamID \(teamIdentifier)"
        }

        if let source, source.lowercased().contains("adhoc") {
            return "本地签名（ad-hoc）"
        }

        return "本地签名（无 TeamID）"
    }
}

@MainActor
final class PermissionsCenter: ObservableObject {
    @Published private(set) var snapshot: PermissionSnapshot = .initial
    @Published private(set) var runtimeDiagnostics: PermissionRuntimeDiagnostics

    private let runtimePolicy = AppRuntimePolicy.current()
    private let defaults: UserDefaults
    private let didPromptAccessibilityKey = "permissions.didPromptAccessibility"
    private let accessibilityPromptFingerprintKey = "permissions.accessibilityPromptFingerprint"
    private let autoPromptedMicrophoneOnLaunchKey = "permissions.autoPromptedMicrophoneOnLaunch.v1"
    private let autoPromptedAccessibilityOnLaunchKey = "permissions.autoPromptedAccessibilityOnLaunch.v1"
    private let microphoneStateResolver: (() -> PermissionState)?
    private let microphonePromptRequester: (() -> Void)?
    private let accessibilityStateResolver: (() -> PermissionState)?
    private let isAccessibilityTrusted: (() -> Bool)?
    private let accessibilityPromptFingerprintProvider: (() -> String)?
    private let accessibilityPromptRequester: (() -> Void)?
    private let accessibilityPollingAttemptCount: Int
    private let accessibilityPollingIntervalNanoseconds: UInt64
    private let pollingSleep: (UInt64) async -> Void
    private let runtimeDiagnosticsProvider: () -> PermissionRuntimeDiagnostics
    private var accessibilityPollingTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        microphoneStateResolver: (() -> PermissionState)? = nil,
        microphonePromptRequester: (() -> Void)? = nil,
        accessibilityStateResolver: (() -> PermissionState)? = nil,
        isAccessibilityTrusted: (() -> Bool)? = nil,
        accessibilityPromptFingerprintProvider: (() -> String)? = nil,
        accessibilityPromptRequester: (() -> Void)? = nil,
        accessibilityPollingAttemptCount: Int = 25,
        accessibilityPollingIntervalNanoseconds: UInt64 = 1_000_000_000,
        pollingSleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        runtimeDiagnosticsProvider: @escaping () -> PermissionRuntimeDiagnostics = {
            PermissionRuntimeDiagnostics.current()
        }
    ) {
        self.defaults = defaults
        self.microphoneStateResolver = microphoneStateResolver
        self.microphonePromptRequester = microphonePromptRequester
        self.accessibilityStateResolver = accessibilityStateResolver
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.accessibilityPromptFingerprintProvider = accessibilityPromptFingerprintProvider
        self.accessibilityPromptRequester = accessibilityPromptRequester
        self.accessibilityPollingAttemptCount = max(1, accessibilityPollingAttemptCount)
        self.accessibilityPollingIntervalNanoseconds = accessibilityPollingIntervalNanoseconds
        self.pollingSleep = pollingSleep
        self.runtimeDiagnosticsProvider = runtimeDiagnosticsProvider
        self.runtimeDiagnostics = runtimeDiagnosticsProvider()
    }

    deinit {
        accessibilityPollingTask?.cancel()
    }

    func refreshStatuses() {
        snapshot = PermissionSnapshot(
            microphone: microphoneState(),
            accessibility: accessibilityState()
        )
        runtimeDiagnostics = runtimeDiagnosticsProvider()
        if snapshot.accessibility == .granted {
            accessibilityPollingTask?.cancel()
            accessibilityPollingTask = nil
        }
    }

    func requestAccess(for kind: PermissionKind) {
        switch kind {
        case .microphone:
            requestMicrophoneAccess()
        case .accessibility:
            requestAccessibilityAccess()
        }
    }

    func autoRequestOnLaunchIfNeeded() {
        refreshStatuses()

        if
            snapshot.microphone == .notRequested,
            !defaults.bool(forKey: autoPromptedMicrophoneOnLaunchKey)
        {
            defaults.set(true, forKey: autoPromptedMicrophoneOnLaunchKey)
            requestMicrophoneAccess()
        }

        if
            snapshot.accessibility == .notRequested,
            !defaults.bool(forKey: autoPromptedAccessibilityOnLaunchKey)
        {
            defaults.set(true, forKey: autoPromptedAccessibilityOnLaunchKey)
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
        if let microphonePromptRequester {
            microphonePromptRequester()
            refreshStatuses()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatuses()
            }
        }
    }

    private func requestAccessibilityAccess() {
        snapshot.accessibility = .pending
        defaults.set(true, forKey: didPromptAccessibilityKey)
        defaults.set(currentAccessibilityPromptFingerprint(), forKey: accessibilityPromptFingerprintKey)
        if let accessibilityPromptRequester {
            accessibilityPromptRequester()
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        startAccessibilityPolling()
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

        let trusted = isAccessibilityTrusted?() ?? AXIsProcessTrusted()
        if trusted {
            defaults.set(false, forKey: didPromptAccessibilityKey)
            defaults.removeObject(forKey: accessibilityPromptFingerprintKey)
            return .granted
        }

        guard defaults.bool(forKey: didPromptAccessibilityKey) else {
            return .notRequested
        }

        if
            let promptedFingerprint = defaults.string(forKey: accessibilityPromptFingerprintKey),
            promptedFingerprint != currentAccessibilityPromptFingerprint()
        {
            defaults.set(false, forKey: didPromptAccessibilityKey)
            defaults.removeObject(forKey: accessibilityPromptFingerprintKey)
            return .notRequested
        }

        // Avoid stale "denied" when the accessibility entry was manually removed.
        // For untrusted state we let user re-request from UI and system settings.
        return .notRequested
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
                return "已允许，可读取选区并把文本直接写进其他应用输入框。"
            case .notRequested:
                return "未允许时只能走剪贴板兜底，无法稳定直写到目标输入框。"
            case .pending:
                return "权限向导已打开，请在系统设置里完成。"
            case .denied:
                return "已拒绝，读取选区与 AX 直写不可用。"
            case .notRequired:
                return "不需要。"
            }
        }
    }

    private func guidanceText(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "先点“请求”，如果被拒绝，请到 系统设置 > 隐私与安全性 > 麦克风 开启 PulseType。若每次启动都重复弹窗，请确认只保留 \(runtimePolicy.installPath)。"
        case .accessibility:
            return "先点“请求”，再到 系统设置 > 隐私与安全性 > 辅助功能 开启 PulseType。若列表里有多个同名项，只保留当前正在运行的 PulseType。"
        }
    }

    private func currentAccessibilityPromptFingerprint() -> String {
        if let accessibilityPromptFingerprintProvider {
            return accessibilityPromptFingerprintProvider()
        }

        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? bundlePath
        let attributes = (try? FileManager.default.attributesOfItem(atPath: executablePath)) ?? [:]
        let modificationDate = attributes[.modificationDate] as? Date
        let timestamp = Int((modificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(bundlePath)|\(executablePath)|\(timestamp)"
    }

    private func startAccessibilityPolling() {
        accessibilityPollingTask?.cancel()
        accessibilityPollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<self.accessibilityPollingAttemptCount {
                await self.pollingSleep(self.accessibilityPollingIntervalNanoseconds)
                if Task.isCancelled {
                    return
                }
                self.refreshStatuses()
                if self.snapshot.accessibility == .granted {
                    return
                }
            }
        }
    }
}
