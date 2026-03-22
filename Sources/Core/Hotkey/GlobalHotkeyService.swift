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
    private var hasActivated = false
    private var globalFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var wakeTapState = ModifierTapState()
    private var cancelTapState = ModifierTapState()

    init(
        interactionCoordinator: InteractionCoordinator,
        hotkeyStateStore: HotkeyStateStore
    ) {
        self.interactionCoordinator = interactionCoordinator
        self.hotkeyStateStore = hotkeyStateStore
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
            if self.hotkeyStateStore.cancelTriggerMode == .shortcut {
                self.interactionCoordinator.handleCancelInput()
            }
        }

        installModifierMonitors()
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
                self?.interactionCoordinator.handleCancelInput()
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
        let isPressedNow = activeFlags.contains(modifier.modifierFlags)
        let hasOtherModifiers = !activeFlags.subtracting(modifier.modifierFlags).isEmpty

        if isPressedNow {
            if !state.isPressed {
                state.isPressed = true
                state.pressedAt = Date()
                state.sawForeignInput = hasOtherModifiers
            } else if hasOtherModifiers {
                state.sawForeignInput = true
            }
            return
        }

        guard state.isPressed else {
            return
        }

        let duration = Date().timeIntervalSince(state.pressedAt ?? Date())
        let shouldTrigger = duration <= 0.7 && !state.sawForeignInput && !hasOtherModifiers
        state.reset()
        if shouldTrigger {
            trigger()
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
}
