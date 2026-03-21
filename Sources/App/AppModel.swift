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
    let textOutputCoordinator: TextOutputCoordinator
    let contextDetector: ContextDetector
    let permissionsCenter: PermissionsCenter
    let localStore: LocalStore
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
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        permissionsCenter: PermissionsCenter,
        localStore: LocalStore,
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
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.permissionsCenter = permissionsCenter
        self.localStore = localStore
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
        let contextDetector = AccessibilityContextDetector()
        let textOutputCoordinator = AccessibilityTextOutputCoordinator(
            logger: TextOutputLogger(diagnosticsDirectory: store.diagnosticsDirectory)
        )
        let interactionCoordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: permissionsCenter,
            audioCaptureService: audioCaptureService,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: speechProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: contextDetector
        )
        return AppModel(
            sessionStore: sessionStore,
            hotkeyCoordinator: HotkeyCoordinator.defaultConfiguration,
            globalHotkeyService: GlobalHotkeyService(interactionCoordinator: interactionCoordinator),
            interactionCoordinator: interactionCoordinator,
            audioCaptureService: audioCaptureService,
            providerSettingsStore: providerSettingsStore,
            speechProviderRegistry: speechProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: contextDetector,
            permissionsCenter: permissionsCenter,
            localStore: store,
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
