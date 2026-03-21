import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let hotkeyCoordinator: HotkeyCoordinator
    let globalHotkeyService: GlobalHotkeyService
    let interactionCoordinator: InteractionCoordinator
    let audioCaptureService: AudioCaptureService
    let speechProvider: SpeechProvider
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
        speechProvider: SpeechProvider,
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
        self.speechProvider = speechProvider
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.permissionsCenter = permissionsCenter
        self.localStore = localStore
        self.diagnosticsCenter = diagnosticsCenter
        self.statusPulseHUDController = statusPulseHUDController

        bindStatusPulse()
        activateGlobalHotkeys()
    }

    static func bootstrap() -> AppModel {
        let store = LocalStore.bootstrap()
        let sessionStore = SessionStore()
        let interactionCoordinator = InteractionCoordinator(sessionStore: sessionStore)
        return AppModel(
            sessionStore: sessionStore,
            hotkeyCoordinator: HotkeyCoordinator.defaultConfiguration,
            globalHotkeyService: GlobalHotkeyService(interactionCoordinator: interactionCoordinator),
            interactionCoordinator: interactionCoordinator,
            audioCaptureService: StubAudioCaptureService(),
            speechProvider: PlaceholderSpeechProvider(),
            textOutputCoordinator: StubTextOutputCoordinator(),
            contextDetector: StubContextDetector(),
            permissionsCenter: PermissionsCenter(),
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
    }
}
