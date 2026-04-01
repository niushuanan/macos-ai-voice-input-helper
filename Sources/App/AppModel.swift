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
    let magicianFeatureToggleStore: MagicianFeatureToggleStore
    let mailAddressBookStore: MailAddressBookStore
    let providerSettingsStore: ProviderSettingsStore
    let asrDictionaryStore: ASRDictionaryStore
    let localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager
    let speechProviderRegistry: SpeechProviderRegistry
    let rewriteProviderRegistry: RewriteProviderRegistry
    let textOutputCoordinator: TextOutputCoordinator
    let contextDetector: ContextDetector
    let appScenePolicyStore: AppScenePolicyStore
    let permissionsCenter: PermissionsCenter
    let localStore: LocalStore
    let localHistoryStore: LocalHistoryStore
    let brainstormDurationProfileStore: BrainstormDurationProfileStore
    let diagnosticsCenter: DiagnosticsCenter
    let statusPulseHUDController: StatusPulseHUDController
    let toastPresenter: ToastPresenter
    private let runtimePolicy = AppRuntimePolicy.current()
    private var cancellables = Set<AnyCancellable>()
    private var controlCenterWindowOpener: (() -> Void)?

    init(
        controlCenterState: ControlCenterState,
        sessionStore: SessionStore,
        hotkeyStateStore: HotkeyStateStore,
        globalHotkeyService: GlobalHotkeyService,
        interactionCoordinator: InteractionCoordinator,
        audioCaptureService: AudioCaptureService,
        skillRuleStore: SkillRuleStore,
        magicianFeatureToggleStore: MagicianFeatureToggleStore,
        mailAddressBookStore: MailAddressBookStore,
        providerSettingsStore: ProviderSettingsStore,
        asrDictionaryStore: ASRDictionaryStore,
        localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager,
        speechProviderRegistry: SpeechProviderRegistry,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        appScenePolicyStore: AppScenePolicyStore,
        permissionsCenter: PermissionsCenter,
        localStore: LocalStore,
        localHistoryStore: LocalHistoryStore,
        brainstormDurationProfileStore: BrainstormDurationProfileStore,
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
        self.magicianFeatureToggleStore = magicianFeatureToggleStore
        self.mailAddressBookStore = mailAddressBookStore
        self.providerSettingsStore = providerSettingsStore
        self.asrDictionaryStore = asrDictionaryStore
        self.localSenseVoiceRuntimeManager = localSenseVoiceRuntimeManager
        self.speechProviderRegistry = speechProviderRegistry
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.appScenePolicyStore = appScenePolicyStore
        self.permissionsCenter = permissionsCenter
        self.localStore = localStore
        self.localHistoryStore = localHistoryStore
        self.brainstormDurationProfileStore = brainstormDurationProfileStore
        self.diagnosticsCenter = diagnosticsCenter
        self.statusPulseHUDController = statusPulseHUDController
        self.toastPresenter = toastPresenter

        migrateLegacyLocalState()
        permissionsCenter.refreshStatuses()
        permissionsCenter.autoRequestOnLaunchIfNeeded()
        bindStatusPulse()
        bindGlobalHotkeyRuntimeState()
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
        let magicianFeatureToggleStore = MagicianFeatureToggleStore()
        let mailAddressBookStore = MailAddressBookStore()
        let credentialStore = CredentialStoreFactory.makeProviderCredentialStore(
            credentialsDirectory: store.credentialsDirectory
        )
        let providerSettingsStore = ProviderSettingsStore(
            credentialStore: credentialStore
        )
        let asrDictionaryStore = ASRDictionaryStore()
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
        let brainstormDurationProfileStore = BrainstormDurationProfileStore(
            historyDirectory: store.historyDirectory
        )
        let speechPipelineLogger = SpeechPipelineLogger(
            diagnosticsDirectory: store.diagnosticsDirectory
        )
        let workflowTelemetryReporter = WorkflowTelemetryReporter(
            diagnosticsDirectory: store.diagnosticsDirectory,
            speechPipelineLogger: speechPipelineLogger
        )
        let v4RuntimeSwitchStore = V4RuntimeSwitchStore()
        let v4MagicianRuntime = V4MagicianRuntimeAdapter(
            providerSettingsStore: providerSettingsStore,
            featureToggleStore: magicianFeatureToggleStore
        )
        let controlCenterState = ControlCenterState(localHistoryStore: localHistoryStore)
        let hotkeyStateStore = HotkeyStateStore()
        let toastPresenter = ToastPresenter()
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
            brainstormDurationProfileStore: brainstormDurationProfileStore,
            speechPipelineLogger: speechPipelineLogger,
            skillRuleStore: skillRuleStore,
            asrDictionaryStore: asrDictionaryStore,
            mailAddressBookStore: mailAddressBookStore,
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            workflowTelemetryReporter: workflowTelemetryReporter,
            v4MagicianRuntime: v4MagicianRuntime,
            v4RuntimeSwitchStore: v4RuntimeSwitchStore,
            toastPresenter: toastPresenter
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
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            mailAddressBookStore: mailAddressBookStore,
            providerSettingsStore: providerSettingsStore,
            asrDictionaryStore: asrDictionaryStore,
            localSenseVoiceRuntimeManager: localSenseVoiceRuntimeManager,
            speechProviderRegistry: speechProviderRegistry,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: contextDetector,
            appScenePolicyStore: appScenePolicyStore,
            permissionsCenter: permissionsCenter,
            localStore: store,
            localHistoryStore: localHistoryStore,
            brainstormDurationProfileStore: brainstormDurationProfileStore,
            diagnosticsCenter: DiagnosticsCenter(),
            statusPulseHUDController: StatusPulseHUDController(),
            toastPresenter: toastPresenter
        )
    }

    func registerControlCenterWindowOpener(_ opener: @escaping () -> Void) {
        controlCenterWindowOpener = opener
    }

    private func bindStatusPulse() {
        sessionStore.$phase
            .combineLatest(
                sessionStore.$activeLane,
                sessionStore.$statusMessage,
                sessionStore.$hudProgressHint
            )
            .combineLatest(sessionStore.$listeningLevel)
            .map({ payload -> StatusPulsePayload in
                let (state, listeningLevel) = payload
                let (phase, lane, message, progressHint) = state
                return StatusPulsePayload(
                    phase: phase,
                    lane: lane,
                    message: message,
                    progressHint: progressHint,
                    listeningLevel: max(0, min(1, listeningLevel))
                )
            })
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] (payload: StatusPulsePayload) in
                self?.statusPulseHUDController.show(
                    phase: payload.phase,
                    lane: payload.lane,
                    message: payload.message,
                    progressHint: payload.progressHint,
                    listeningLevel: payload.listeningLevel
                )
            }
            .store(in: &cancellables)
    }

    private func activateGlobalHotkeys() {
        globalHotkeyService.activate()
        _ = audioCaptureService.purgeStaleTemporaryFiles(olderThan: 24 * 60 * 60)
    }

    private func bindGlobalHotkeyRuntimeState() {
        sessionStore.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.globalHotkeyService.updateSessionPhase(phase)
            }
            .store(in: &cancellables)

        hotkeyStateStore.$cancelTriggerMode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.globalHotkeyService.refreshRuntimeState()
            }
            .store(in: &cancellables)
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

        let installPath = runtimePolicy.installPath
        guard Bundle.main.bundlePath == installPath else {
            return
        }

        purgeDerivedDataDebugAppCopies()

        if
            let fingerprint = defaults.string(forKey: "permissions.accessibilityPromptFingerprint"),
            !fingerprint.contains(installPath)
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
                    url.lastPathComponent == self.runtimePolicy.installURL.lastPathComponent,
                    url.path.contains("/Build/Products/"),
                    url.path != self.runtimePolicy.installPath
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
                    atPath: self.runtimePolicy.launchServicesToolPath
                )
            else {
                return
            }

            let lsregister = self.runtimePolicy.launchServicesToolPath
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
    let progressHint: Double
    let listeningLevel: Double
}
