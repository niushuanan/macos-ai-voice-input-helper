import AppKit
import Combine
import Foundation
import KeyboardShortcuts

enum ModifierDoubleTapAction {
    case waitingSecondTap
    case trigger
}

enum WakeModifierPressAction {
    case none
    case tap
    case holdBegan
    case holdEnded
}

struct WakeModifierPressStateMachine {
    let holdInterval: TimeInterval
    let tapInterval: TimeInterval
    private let intervalTolerance: TimeInterval = 0.000_001
    private(set) var isPressed = false
    private(set) var pressedAt: Date?
    private(set) var sawForeignInput = false
    private(set) var holdTriggered = false

    mutating func beginPress(
        at date: Date,
        hasForeignInput: Bool
    ) {
        isPressed = true
        pressedAt = date
        sawForeignInput = hasForeignInput
        holdTriggered = false
    }

    mutating func registerForeignInput() {
        guard isPressed else {
            return
        }
        sawForeignInput = true
    }

    mutating func evaluateHold(at date: Date) -> WakeModifierPressAction {
        guard
            isPressed,
            !holdTriggered,
            !sawForeignInput,
            let pressedAt
        else {
            return .none
        }

        if date.timeIntervalSince(pressedAt) >= holdInterval - intervalTolerance {
            holdTriggered = true
            return .holdBegan
        }
        return .none
    }

    mutating func endPress(
        at date: Date,
        hasOtherModifierFamilies: Bool,
        sameFamilyStillPressed: Bool
    ) -> WakeModifierPressAction {
        guard isPressed else {
            return .none
        }

        defer { reset() }

        if holdTriggered {
            return .holdEnded
        }

        let duration = date.timeIntervalSince(pressedAt ?? date)
        let shouldTap = duration <= tapInterval + intervalTolerance
            && !sawForeignInput
            && !hasOtherModifierFamilies
            && !sameFamilyStillPressed
        return shouldTap ? .tap : .none
    }

    mutating func reset() {
        isPressed = false
        pressedAt = nil
        sawForeignInput = false
        holdTriggered = false
    }
}

struct ModifierDoubleTapStateMachine {
    let interval: TimeInterval
    private let intervalTolerance: TimeInterval = 0.000_001
    private(set) var firstTapAt: Date?

    mutating func registerTap(at date: Date) -> ModifierDoubleTapAction {
        if
            let firstTapAt,
            date.timeIntervalSince(firstTapAt) <= interval + intervalTolerance
        {
            self.firstTapAt = nil
            return .trigger
        }

        firstTapAt = date
        return .waitingSecondTap
    }

    mutating func clearIfExpired(at date: Date) -> Bool {
        guard let firstTapAt else {
            return false
        }
        guard date.timeIntervalSince(firstTapAt) >= interval - intervalTolerance else {
            return false
        }
        self.firstTapAt = nil
        return true
    }

    mutating func reset() {
        firstTapAt = nil
    }
}

@MainActor
final class GlobalHotkeyService {
    private struct ModifierTapState {
        var isPressed = false
        var pressedAt: Date?
        var sawForeignInput = false

        mutating func reset() {
            isPressed = false
            pressedAt = nil
            sawForeignInput = false
        }
    }

    private let interactionCoordinator: InteractionCoordinator
    private let hotkeyStateStore: HotkeyStateStore
    private let screenCaptureActivityDetector: () -> Bool
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    private var currentSessionPhase: SessionPhase = .idle
    private var cancelShortcutRuntimeEnabled = true
    private var globalFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var wakePressStateMachine = WakeModifierPressStateMachine(
        holdInterval: 0.18,
        tapInterval: 0.7
    )
    private var cancelTapState = ModifierTapState()
    private var brainstormTapState = ModifierTapState()
    private var wakeAndBrainstormArbitration = ModifierDoubleTapStateMachine(interval: 0.35)
    private var brainstormDoubleTapStateMachine = ModifierDoubleTapStateMachine(interval: 0.35)
    private var wakeArbitrationWorkItem: DispatchWorkItem?
    private var wakeHoldWorkItem: DispatchWorkItem?
    private var wakeHoldSessionActive = false

    init(
        interactionCoordinator: InteractionCoordinator,
        hotkeyStateStore: HotkeyStateStore,
        screenCaptureActivityDetector: (() -> Bool)? = nil
    ) {
        self.interactionCoordinator = interactionCoordinator
        self.hotkeyStateStore = hotkeyStateStore
        self.screenCaptureActivityDetector = screenCaptureActivityDetector ?? {
            GlobalHotkeyService.defaultScreenCaptureActivityDetector()
        }
    }

    func activate() {
        guard !hasActivated else {
            return
        }
        hasActivated = true

        KeyboardShortcuts.onKeyUp(for: .cancelSession) { [weak self] in
            guard let self else {
                return
            }
            if self.hotkeyStateStore.cancelTriggerMode == .shortcut, self.shouldHandleCancelInput {
                self.interactionCoordinator.handleCancelInput()
            }
        }

        hotkeyStateStore.$lastUpdatedAt
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshRuntimeState()
            }
            .store(in: &cancellables)

        installWorkspaceObservers()
        installModifierMonitors()
        refreshRuntimeState()
    }

    func updateSessionPhase(_ phase: SessionPhase) {
        guard currentSessionPhase != phase else {
            return
        }
        currentSessionPhase = phase
        if phase != .listening {
            wakeHoldSessionActive = false
        }
        reconcileCancelShortcutAvailability()
    }

    func refreshRuntimeState() {
        if !shouldArbitrateWakeAndBrainstormModifier {
            clearWakeArbitration()
        }

        if hotkeyStateStore.brainstormTriggerType != .doubleTapModifier {
            brainstormDoubleTapStateMachine.reset()
        }

        reconcileCancelShortcutAvailability()
    }

    private func installModifierMonitors() {
        removeModifierMonitors()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else {
                return
            }
            Task { @MainActor in
                self.handleFlagsChanged(event)
            }
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
            return event
        }
    }

    private func removeModifierMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        clearWakeHoldCheck()
        wakePressStateMachine.reset()
        wakeHoldSessionActive = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        processWakeModifierEvent(event)

        if hotkeyStateStore.cancelTriggerMode == .modifierTap {
            processModifierEvent(
                event,
                modifier: hotkeyStateStore.cancelModifier,
                state: &cancelTapState
            ) { [weak self] in
                guard let self else {
                    return
                }
                guard self.shouldHandleCancelInput else {
                    return
                }
                self.interactionCoordinator.handleCancelInput()
            }
        } else {
            cancelTapState.reset()
        }

        if hotkeyStateStore.brainstormModifier == hotkeyStateStore.wakeModifier {
            brainstormTapState.reset()
            return
        }
        processModifierEvent(
            event,
            modifier: hotkeyStateStore.brainstormModifier,
            state: &brainstormTapState
        ) { [weak self] in
            self?.handleBrainstormDoubleModifierTap()
        }
    }

    private func processWakeModifierEvent(_ event: NSEvent) {
        let modifier = hotkeyStateStore.wakeModifier
        let trackedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let activeFlags = event.modifierFlags.intersection(trackedFlags)
        let isTargetKeyEvent = event.keyCode == modifier.keyCode
        let hasOtherModifierFamilies = !activeFlags.subtracting(modifier.modifierFlags).isEmpty

        if isTargetKeyEvent {
            let now = Date()
            if !wakePressStateMachine.isPressed {
                wakePressStateMachine.beginPress(
                    at: now,
                    hasForeignInput: hasOtherModifierFamilies
                )
                scheduleWakeHoldCheck()
                return
            }

            clearWakeHoldCheck()
            let action = wakePressStateMachine.endPress(
                at: now,
                hasOtherModifierFamilies: hasOtherModifierFamilies,
                sameFamilyStillPressed: activeFlags.contains(modifier.modifierFlags)
            )
            handleWakePressAction(action)
            return
        }

        guard wakePressStateMachine.isPressed else {
            return
        }

        if HotkeyModifier.from(keyCode: event.keyCode) != nil {
            wakePressStateMachine.registerForeignInput()
        }

        if !activeFlags.contains(modifier.modifierFlags) {
            clearWakeHoldCheck()
            wakePressStateMachine.reset()
        }
    }

    private func scheduleWakeHoldCheck() {
        clearWakeHoldCheck()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.wakeHoldWorkItem = nil
            let action = self.wakePressStateMachine.evaluateHold(at: Date())
            self.handleWakePressAction(action)
        }
        wakeHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + wakePressStateMachine.holdInterval,
            execute: workItem
        )
    }

    private func clearWakeHoldCheck() {
        wakeHoldWorkItem?.cancel()
        wakeHoldWorkItem = nil
    }

    private func handleWakePressAction(_ action: WakeModifierPressAction) {
        switch action {
        case .none:
            break
        case .tap:
            handleWakeModifierTap()
        case .holdBegan:
            handleWakeModifierHoldBegan()
        case .holdEnded:
            handleWakeModifierHoldEnded()
        }
    }

    private func handleWakeModifierHoldBegan() {
        clearWakeArbitration()
        brainstormDoubleTapStateMachine.reset()

        guard canStartWakeHoldSession else {
            return
        }
        wakeHoldSessionActive = true
        interactionCoordinator.handleWakeInput(context: .magicianHold)
    }

    private func handleWakeModifierHoldEnded() {
        guard wakeHoldSessionActive else {
            return
        }
        wakeHoldSessionActive = false

        guard currentSessionPhase == .listening else {
            return
        }
        interactionCoordinator.handleStopInput()
    }

    private func handleWakeModifierTap() {
        guard shouldArbitrateWakeAndBrainstormModifier else {
            clearWakeArbitration()
            interactionCoordinator.handleWakeInput(context: .dictationTap)
            return
        }

        switch wakeAndBrainstormArbitration.registerTap(at: Date()) {
        case .waitingSecondTap:
            scheduleWakeArbitrationTimeout()
        case .trigger:
            wakeArbitrationWorkItem?.cancel()
            wakeArbitrationWorkItem = nil
            if shouldHandleBrainstormInput {
                interactionCoordinator.handleBrainstormInput()
            } else {
                interactionCoordinator.handleWakeInput(context: .dictationTap)
            }
        }
    }

    private func scheduleWakeArbitrationTimeout() {
        wakeArbitrationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.wakeArbitrationWorkItem = nil
            if self.wakeAndBrainstormArbitration.clearIfExpired(at: Date()) {
                self.interactionCoordinator.handleWakeInput(context: .dictationTap)
            }
        }
        wakeArbitrationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + wakeAndBrainstormArbitration.interval,
            execute: workItem
        )
    }

    private func clearWakeArbitration() {
        wakeArbitrationWorkItem?.cancel()
        wakeArbitrationWorkItem = nil
        wakeAndBrainstormArbitration.reset()
    }

    private func handleBrainstormDoubleModifierTap() {
        guard shouldHandleBrainstormInput else {
            brainstormDoubleTapStateMachine.reset()
            return
        }

        switch brainstormDoubleTapStateMachine.registerTap(at: Date()) {
        case .waitingSecondTap:
            break
        case .trigger:
            interactionCoordinator.handleBrainstormInput()
        }
    }

    private func processModifierEvent(
        _ event: NSEvent,
        modifier: HotkeyModifier,
        state: inout ModifierTapState,
        trigger: () -> Void
    ) {
        let trackedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let activeFlags = event.modifierFlags.intersection(trackedFlags)
        let isTargetKeyEvent = event.keyCode == modifier.keyCode
        let hasOtherModifierFamilies = !activeFlags.subtracting(modifier.modifierFlags).isEmpty

        if isTargetKeyEvent {
            if !state.isPressed {
                state.isPressed = true
                state.pressedAt = Date()
                state.sawForeignInput = hasOtherModifierFamilies
                return
            }

            let duration = Date().timeIntervalSince(state.pressedAt ?? Date())
            let sameFamilyStillPressed = activeFlags.contains(modifier.modifierFlags)
            let shouldTrigger = duration <= 0.7
                && !state.sawForeignInput
                && !hasOtherModifierFamilies
                && !sameFamilyStillPressed
            state.reset()
            if shouldTrigger {
                trigger()
            }
            return
        }

        guard state.isPressed else {
            return
        }

        if HotkeyModifier.from(keyCode: event.keyCode) != nil {
            state.sawForeignInput = true
        }

        if !activeFlags.contains(modifier.modifierFlags) {
            state.reset()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        _ = event
        markForeignKeyInput()
    }

    private func markForeignKeyInput() {
        if wakePressStateMachine.isPressed {
            wakePressStateMachine.registerForeignInput()
        }
        if cancelTapState.isPressed {
            cancelTapState.sawForeignInput = true
        }
        if brainstormTapState.isPressed {
            brainstormTapState.sawForeignInput = true
        }
    }

    private var canStartWakeHoldSession: Bool {
        switch currentSessionPhase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private var shouldHandleCancelInput: Bool {
        isCancellationPhase(currentSessionPhase) && !screenCaptureActivityDetector()
    }

    private var shouldHandleBrainstormInput: Bool {
        isBrainstormPhase(currentSessionPhase) && !screenCaptureActivityDetector()
    }

    private var shouldArbitrateWakeAndBrainstormModifier: Bool {
        hotkeyStateStore.brainstormTriggerType == .doubleTapModifier
            && hotkeyStateStore.brainstormModifier == hotkeyStateStore.wakeModifier
            && shouldHandleBrainstormInput
    }

    private func reconcileCancelShortcutAvailability() {
        let shouldEnable = hotkeyStateStore.cancelTriggerMode == .shortcut && shouldHandleCancelInput
        guard shouldEnable != cancelShortcutRuntimeEnabled else {
            return
        }

        cancelShortcutRuntimeEnabled = shouldEnable
        if shouldEnable {
            KeyboardShortcuts.enable(.cancelSession)
        } else {
            KeyboardShortcuts.disable(.cancelSession)
        }
        hotkeyStateStore.refresh()
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let notificationNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for notificationName in notificationNames {
            let observer = notificationCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRuntimeState()
                }
            }
            workspaceNotificationObservers.append(observer)
        }
    }

    private func isCancellationPhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .listening, .transcribing, .rewriting, .inserting:
            return true
        case .idle, .cancelled, .error:
            return false
        }
    }

    private func isBrainstormPhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .idle, .cancelled, .error, .listening:
            return true
        case .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private static func defaultScreenCaptureActivityDetector() -> Bool {
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))

        if runningBundleIDs.contains("com.apple.screencaptureui") {
            return true
        }

        if
            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            frontBundleID == "com.apple.screenshot.launcher"
        {
            return true
        }

        return false
    }
}
