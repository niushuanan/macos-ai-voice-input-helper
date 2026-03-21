import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let hotkeyCoordinator: HotkeyCoordinator
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
    }

    static func bootstrap() -> AppModel {
        let store = LocalStore.bootstrap()
        let sessionStore = SessionStore()
        return AppModel(
            sessionStore: sessionStore,
            hotkeyCoordinator: HotkeyCoordinator.defaultConfiguration,
            interactionCoordinator: InteractionCoordinator(sessionStore: sessionStore),
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
}
