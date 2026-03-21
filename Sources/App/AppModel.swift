import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let hotkeyCoordinator: HotkeyCoordinator
    let audioCaptureService: AudioCaptureService
    let speechProvider: SpeechProvider
    let textOutputCoordinator: TextOutputCoordinator
    let contextDetector: ContextDetector
    let permissionsCenter: PermissionsCenter
    let localStore: LocalStore
    let diagnosticsCenter: DiagnosticsCenter

    init(
        sessionStore: SessionStore,
        hotkeyCoordinator: HotkeyCoordinator,
        audioCaptureService: AudioCaptureService,
        speechProvider: SpeechProvider,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        permissionsCenter: PermissionsCenter,
        localStore: LocalStore,
        diagnosticsCenter: DiagnosticsCenter
    ) {
        self.sessionStore = sessionStore
        self.hotkeyCoordinator = hotkeyCoordinator
        self.audioCaptureService = audioCaptureService
        self.speechProvider = speechProvider
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.permissionsCenter = permissionsCenter
        self.localStore = localStore
        self.diagnosticsCenter = diagnosticsCenter
    }

    static func bootstrap() -> AppModel {
        let store = LocalStore.bootstrap()
        return AppModel(
            sessionStore: SessionStore(),
            hotkeyCoordinator: HotkeyCoordinator.defaultConfiguration,
            audioCaptureService: StubAudioCaptureService(),
            speechProvider: PlaceholderSpeechProvider(),
            textOutputCoordinator: StubTextOutputCoordinator(),
            contextDetector: StubContextDetector(),
            permissionsCenter: PermissionsCenter(),
            localStore: store,
            diagnosticsCenter: DiagnosticsCenter()
        )
    }
}
