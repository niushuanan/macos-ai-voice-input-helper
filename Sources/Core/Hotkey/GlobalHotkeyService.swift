import AppKit
import Foundation
import KeyboardShortcuts

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
    private var hasActivated = false
    private var currentSessionPhase: SessionPhase = .idle
    private var cancelShortcutRuntimeEnabled = true
    private var globalFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var wakeTapState = ModifierTapState()
    private var cancelTapState = ModifierTapState()

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

        KeyboardShortcuts.onKeyUp(for: .wakeSession) { [weak self] in
            guard let self else {
                return
            }
            if self.hotkeyStateStore.wakeTriggerMode == .shortcut {
                self.interactionCoordinator.handleWakeInput(context: .dictation)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .cancelSession) { [weak self] in
            guard let self else {
                return
            }
            if self.hotkeyStateStore.cancelTriggerMode == .shortcut, self.shouldHandleCancelInput {
                self.interactionCoordinator.handleCancelInput()
            }
        }

        installWorkspaceObservers()
        installModifierMonitors()
        reconcileCancelShortcutAvailability()
    }

    func updateSessionPhase(_ phase: SessionPhase) {
        guard currentSessionPhase != phase else {
            return
        }
        currentSessionPhase = phase
        reconcileCancelShortcutAvailability()
    }

    func refreshRuntimeState() {
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

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in
                self?.markForeignKeyInput()
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.markForeignKeyInput()
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
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        if hotkeyStateStore.wakeTriggerMode == .modifierTap {
            processModifierEvent(
                event,
                modifier: hotkeyStateStore.wakeModifier,
                state: &wakeTapState
            ) { [weak self] in
                self?.interactionCoordinator.handleWakeInput(context: .dictation)
            }
        } else {
            wakeTapState.reset()
        }

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

    private func markForeignKeyInput() {
        if wakeTapState.isPressed {
            wakeTapState.sawForeignInput = true
        }
        if cancelTapState.isPressed {
            cancelTapState.sawForeignInput = true
        }
    }

    private var shouldHandleCancelInput: Bool {
        isCancellationPhase(currentSessionPhase) && !screenCaptureActivityDetector()
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
                    self?.reconcileCancelShortcutAvailability()
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
