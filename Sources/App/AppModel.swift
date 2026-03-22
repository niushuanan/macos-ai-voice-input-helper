import AppKit
import Combine
import Foundation

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class ToastPresenter: ObservableObject {
    @Published private(set) var message: ToastMessage?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, duration: TimeInterval = 1.8) {
        hideTask?.cancel()
        message = ToastMessage(text: text)

        hideTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.message = nil
            }
        }
    }

    func clear() {
        hideTask?.cancel()
        message = nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    let controlCenterState: ControlCenterState
    let sessionStore: SessionStore
    let hotkeyStateStore: HotkeyStateStore
    let globalHotkeyService: GlobalHotkeyService
    let interactionCoordinator: InteractionCoordinator
    let audioCaptureService: AudioCaptureService
    let skillRuleStore: SkillRuleStore
    let providerSettingsStore: ProviderSettingsStore
    let localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager
    let speechProviderRegistry: SpeechProviderRegistry
    let rewriteProviderRegistry: RewriteProviderRegistry
    let textOutputCoordinator: TextOutputCoordinator
    let contextDetector: ContextDetector
    let appScenePolicyStore: AppScenePolicyStore
    let permissionsCenter: PermissionsCenter
    let localStore: LocalStore
    let localHistoryStore: LocalHistoryStore
    let diagnosticsCenter: DiagnosticsCenter
    let statusPulseHUDController: StatusPulseHUDController
    let toastPresenter: ToastPresenter
    private var cancellables = Set<AnyCancellable>()

    init(
        controlCenterState: ControlCenterState,
        sessionStore: SessionStore,
        hotkeyStateStore: HotkeyStateStore,
        globalHotkeyService: GlobalHotkeyService,
        interactionCoordinator: InteractionCoordinator,
        audioCaptureService: AudioCaptureService,
        skillRuleStore: SkillRuleStore,
        providerSettingsStore: ProviderSettingsStore,
        localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager,
        speechProviderRegistry: SpeechProviderRegistry,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        appScenePolicyStore: AppScenePolicyStore,
        permissionsCenter: PermissionsCenter,
        localStore: LocalStore,
        localHistoryStore: LocalHistoryStore,
        diagnosticsCenter: DiagnosticsCenter,
        statusPulseHUDController: StatusPulseHUDController,
        toastPresenter: ToastPresenter
    ) {
        self.controlCenterState = controlCenterState
        self.sessionStore = sessionStore
        self.hotkeyStateStore = hotkeyStateStore
        self.globalHotkeyService = globalHotkeyService
        self.interactionCoordinator = interactionCoordinator
        self.audioCaptureService = audioCaptureService
        self.skillRuleStore = skillRuleStore
        self.providerSettingsStore = providerSettingsStore
        self.localSenseVoiceRuntimeManager = localSenseVoiceRuntimeManager
        self.speechProviderRegistry = speechProviderRegistry
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.appScenePolicyStore = appScenePolicyStore
        self.permissionsCenter = permissionsCenter
        self.localStore = localStore
        self.localHistoryStore = localHistoryStore
        self.diagnosticsCenter = diagnosticsCenter
        self.statusPulseHUDController = statusPulseHUDController
        self.toastPresenter = toastPresenter

        migrateLegacyLocalState()
        permissionsCenter.refreshStatuses()
        permissionsCenter.autoRequestOnLaunchIfNeeded()
        bindStatusPulse()
        bindAppLifecycle()
        activateGlobalHotkeys()
        probeLocalSenseVoiceRuntime()
    }

    static func bootstrap() -> AppModel {
        let store = LocalStore.bootstrap()
        let sessionStore = SessionStore()
        let permissionsCenter = PermissionsCenter()
        let audioCaptureService = AVAudioRecorderCaptureService(temporaryDirectory: store.temporaryAudioDirectory)
        let skillRuleStore = SkillRuleStore()
        let credentialStore = LocalFileProviderCredentialStore(
            credentialsDirectory: store.credentialsDirectory,
            legacyStores: [
                KeychainProviderCredentialStore(service: "com.niushuanan.PulseType.provider-profile.v4"),
                KeychainProviderCredentialStore(service: "com.niushuanan.PulseType.provider-profile.v3")
            ]
        )
        let providerSettingsStore = ProviderSettingsStore(
            credentialStore: credentialStore
        )
        let localSenseVoiceRuntimeManager = LocalSenseVoiceRuntimeManager(
            runtimeRoot: store.senseVoiceRuntimeDirectory
        )
        let speechProviderRegistry = SpeechProviderRegistry(
            providers: [
                OpenAITranscriptionProvider(),
                DashScopeQwenASRProvider(),
                LocalSenseVoiceProvider()
            ]
        )
        let rewriteProviderRegistry = RewriteProviderRegistry(
            providers: [OpenAIRewriteProvider()]
        )
        let contextDetector = AccessibilityContextDetector()
        let appScenePolicyStore = AppScenePolicyStore()
        let textOutputCoordinator = AccessibilityTextOutputCoordinator(
            logger: TextOutputLogger(diagnosticsDirectory: store.diagnosticsDirectory),
            contextDetector: contextDetector
        )
        let localHistoryStore = LocalHistoryStore(historyDirectory: store.historyDirectory)
        let controlCenterState = ControlCenterState(localHistoryStore: localHistoryStore)
        let hotkeyStateStore = HotkeyStateStore()
        let interactionCoordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: permissionsCenter,
            audioCaptureService: audioCaptureService,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: speechProviderRegistry,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: contextDetector,
            appScenePolicyStore: appScenePolicyStore,
            localHistoryStore: localHistoryStore,
            skillRuleStore: skillRuleStore
        )
        return AppModel(
            controlCenterState: controlCenterState,
            sessionStore: sessionStore,
            hotkeyStateStore: hotkeyStateStore,
            globalHotkeyService: GlobalHotkeyService(
                interactionCoordinator: interactionCoordinator,
                hotkeyStateStore: hotkeyStateStore
            ),
            interactionCoordinator: interactionCoordinator,
            audioCaptureService: audioCaptureService,
            skillRuleStore: skillRuleStore,
            providerSettingsStore: providerSettingsStore,
            localSenseVoiceRuntimeManager: localSenseVoiceRuntimeManager,
            speechProviderRegistry: speechProviderRegistry,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: contextDetector,
            appScenePolicyStore: appScenePolicyStore,
            permissionsCenter: permissionsCenter,
            localStore: store,
            localHistoryStore: localHistoryStore,
            diagnosticsCenter: DiagnosticsCenter(),
            statusPulseHUDController: StatusPulseHUDController(),
            toastPresenter: ToastPresenter()
        )
    }

    private func bindStatusPulse() {
        sessionStore.$phase
            .combineLatest(
                sessionStore.$activeLane,
                sessionStore.$statusMessage,
                sessionStore.$listeningLevel
            )
            .map { phase, lane, message, listeningLevel in
                StatusPulsePayload(
                    phase: phase,
                    lane: lane,
                    message: message,
                    progress: Self.statusProgress(
                        for: phase,
                        listeningLevel: listeningLevel
                    )
                )
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] payload in
                self?.statusPulseHUDController.show(
                    phase: payload.phase,
                    lane: payload.lane,
                    message: payload.message,
                    progress: payload.progress
                )
            }
            .store(in: &cancellables)
    }

    private static func statusProgress(
        for phase: SessionPhase,
        listeningLevel: Double
    ) -> Double {
        _ = listeningLevel
        let value: Double
        switch phase {
        case .listening:
            value = 0.25
        case .transcribing:
            value = 0.50
        case .rewriting:
            value = 0.75
        case .inserting:
            value = 1.0
        case .idle:
            value = 1.0
        case .cancelled:
            value = 0
        case .error:
            value = 0.04
        }
        return (value * 100).rounded() / 100
    }

    private func activateGlobalHotkeys() {
        globalHotkeyService.activate()
        _ = audioCaptureService.purgeStaleTemporaryFiles(olderThan: 24 * 60 * 60)
    }

    private func bindAppLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.permissionsCenter.refreshStatuses()
            }
            .store(in: &cancellables)
    }

    private func probeLocalSenseVoiceRuntime() {
        Task {
            await localSenseVoiceRuntimeManager.detect(
                modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
            )
        }
    }

    private func migrateLegacyLocalState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "KeyboardShortcuts_stopSession")

        guard Bundle.main.bundlePath == "/Applications/PulseType.app" else {
            return
        }

        purgeDerivedDataDebugAppCopies()

        if
            let fingerprint = defaults.string(forKey: "permissions.accessibilityPromptFingerprint"),
            !fingerprint.contains("/Applications/PulseType.app")
        {
            defaults.set(false, forKey: "permissions.didPromptAccessibility")
            defaults.removeObject(forKey: "permissions.accessibilityPromptFingerprint")
        }
    }

    private func purgeDerivedDataDebugAppCopies() {
        let derivedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)

        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: derivedRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            var removedPaths: [String] = []
            for case let url as URL in enumerator {
                guard
                    url.lastPathComponent == "PulseType.app",
                    url.path.contains("/Build/Products/"),
                    url.path != "/Applications/PulseType.app"
                else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: url)
                    removedPaths.append(url.path)
                } catch {
                    continue
                }
            }

            guard
                !removedPaths.isEmpty,
                fileManager.isExecutableFile(
                    atPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
                )
            else {
                return
            }

            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
            for path in removedPaths {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: lsregister)
                process.arguments = ["-u", path]
                try? process.run()
                process.waitUntilExit()
            }

            let gcProcess = Process()
            gcProcess.executableURL = URL(fileURLWithPath: lsregister)
            gcProcess.arguments = ["-gc"]
            try? gcProcess.run()
            gcProcess.waitUntilExit()
        }
    }
}

private struct StatusPulsePayload: Equatable {
    let phase: SessionPhase
    let lane: InputLane
    let message: String
    let progress: Double
}
