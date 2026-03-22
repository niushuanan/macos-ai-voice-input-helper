import AppKit
import Combine
import Foundation

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
        statusPulseHUDController: StatusPulseHUDController
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

        migrateLegacyLocalState()
        permissionsCenter.refreshStatuses()
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
        let providerSettingsStore = ProviderSettingsStore(
            credentialStore: KeychainProviderCredentialStore()
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
            logger: TextOutputLogger(diagnosticsDirectory: store.diagnosticsDirectory)
        )
        let localHistoryStore = LocalHistoryStore(historyDirectory: store.historyDirectory)
        let controlCenterState = ControlCenterState(localHistoryStore: localHistoryStore)
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
            hotkeyStateStore: HotkeyStateStore(),
            globalHotkeyService: GlobalHotkeyService(interactionCoordinator: interactionCoordinator),
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
            statusPulseHUDController: StatusPulseHUDController()
        )
    }

    private func bindStatusPulse() {
        sessionStore.$phase
            .combineLatest(sessionStore.$activeLane, sessionStore.$statusMessage)
            .removeDuplicates(by: ==)
            .dropFirst()
            .sink { [weak self] phase, lane, message in
                self?.statusPulseHUDController.show(phase: phase, lane: lane, message: message)
            }
            .store(in: &cancellables)
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

        if
            let fingerprint = defaults.string(forKey: "permissions.accessibilityPromptFingerprint"),
            !fingerprint.contains("/Applications/PulseType.app")
        {
            defaults.set(false, forKey: "permissions.didPromptAccessibility")
            defaults.removeObject(forKey: "permissions.accessibilityPromptFingerprint")
        }
    }
}
