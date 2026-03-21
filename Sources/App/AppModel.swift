import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let hotkeyCoordinator: HotkeyCoordinator
    let globalHotkeyService: GlobalHotkeyService
    let interactionCoordinator: InteractionCoordinator
    let audioCaptureService: AudioCaptureService
    let providerSettingsStore: ProviderSettingsStore
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
        sessionStore: SessionStore,
        hotkeyCoordinator: HotkeyCoordinator,
        globalHotkeyService: GlobalHotkeyService,
        interactionCoordinator: InteractionCoordinator,
        audioCaptureService: AudioCaptureService,
        providerSettingsStore: ProviderSettingsStore,
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
        self.sessionStore = sessionStore
        self.hotkeyCoordinator = hotkeyCoordinator
        self.globalHotkeyService = globalHotkeyService
        self.interactionCoordinator = interactionCoordinator
        self.audioCaptureService = audioCaptureService
        self.providerSettingsStore = providerSettingsStore
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

        permissionsCenter.refreshStatuses()
        bindStatusPulse()
        bindAppLifecycle()
        activateGlobalHotkeys()
    }

    static func bootstrap() -> AppModel {
        let store = LocalStore.bootstrap()
        let sessionStore = SessionStore()
        let permissionsCenter = PermissionsCenter()
        let audioCaptureService = AVAudioRecorderCaptureService(temporaryDirectory: store.temporaryAudioDirectory)
        let providerSettingsStore = ProviderSettingsStore(
            credentialStore: KeychainProviderCredentialStore()
        )
        let speechProviderRegistry = SpeechProviderRegistry(
            providers: [OpenAITranscriptionProvider()]
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
            localHistoryStore: localHistoryStore
        )
        return AppModel(
            sessionStore: sessionStore,
            hotkeyCoordinator: HotkeyCoordinator.defaultConfiguration,
            globalHotkeyService: GlobalHotkeyService(interactionCoordinator: interactionCoordinator),
            interactionCoordinator: interactionCoordinator,
            audioCaptureService: audioCaptureService,
            providerSettingsStore: providerSettingsStore,
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
                self?.providerSettingsStore.refreshCredentialState()
            }
            .store(in: &cancellables)
    }
}
