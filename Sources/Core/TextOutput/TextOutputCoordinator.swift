import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Foundation

enum TextOutputOperation: Equatable {
    case insertText
    case replaceSelectedText
}

enum TextOutputWriteMode: Equatable {
    case finalDelivery
    case streamingChunk
}

struct TextOutputRequest: Equatable {
    let text: String
    let operation: TextOutputOperation
    let focusContext: FocusedAppContext
    let preferredTarget: WritebackTargetSnapshot?
    let writeMode: TextOutputWriteMode

    init(
        text: String,
        operation: TextOutputOperation,
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot? = nil,
        writeMode: TextOutputWriteMode = .finalDelivery
    ) {
        self.text = text
        self.operation = operation
        self.focusContext = focusContext
        self.preferredTarget = preferredTarget
        self.writeMode = writeMode
    }
}

struct WritebackTargetSnapshot: Equatable {
    let appName: String
    let bundleID: String
    let processIdentifier: pid_t?
}

struct FocusedSelectionSnapshot: Equatable {
    let focusContext: FocusedAppContext
    let selectedText: String
}

enum TextOutputPath: String, Codable, Equatable {
    case accessibilitySelectionReplacement
    case pasteFallbackCommandV
    case clipboardOnly
}

struct TextOutputResult: Equatable {
    let appName: String
    let bundleID: String
    let path: TextOutputPath
    let usedFallback: Bool
    let didInsertIntoEditor: Bool
    let operation: TextOutputOperation
}

enum TextOutputError: LocalizedError {
    case emptyText
    case accessibilityPermissionMissing
    case noFocusedElement
    case noEditableTarget
    case accessibilityPathFailed(reason: String)
    case pasteboardUnavailable
    case pasteShortcutInjectionFailed
    case fallbackFailed(primaryReason: String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可写入文本。"
        case .accessibilityPermissionMissing:
            return "AX 直写需要辅助功能权限。"
        case .noFocusedElement:
            return "未找到焦点输入目标。"
        case .noEditableTarget:
            return "当前焦点不可编辑。"
        case let .accessibilityPathFailed(reason):
            return "AX 写入失败：\(reason)"
        case .pasteboardUnavailable:
            return "粘贴兜底不可用，剪贴板访问异常。"
        case .pasteShortcutInjectionFailed:
            return "粘贴兜底失败，无法触发 Command+V。"
        case let .fallbackFailed(primaryReason):
            return "AX 与兜底路径均失败。AX 原因：\(primaryReason)"
        }
    }
}

@MainActor
protocol TextOutputCoordinator {
    var insertionStrategy: String { get }
    func currentSelectionSnapshot() -> FocusedSelectionSnapshot?
    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot?
    func captureSelectionSnapshot(preferredTarget: WritebackTargetSnapshot?) async -> FocusedSelectionSnapshot?
    func write(request: TextOutputRequest) async throws -> TextOutputResult
}

extension TextOutputCoordinator {
    func captureSelectionSnapshot(preferredTarget _: WritebackTargetSnapshot?) async -> FocusedSelectionSnapshot? {
        await captureSelectionSnapshot()
    }
}

@MainActor
class AccessibilityTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "主路径：AX 直写；兜底：剪贴板 + Command+V。"

    let logger: TextOutputLogger
    let contextDetector: ContextDetector

    init(
        logger: TextOutputLogger,
        contextDetector: ContextDetector = AccessibilityContextDetector()
    ) {
        self.logger = logger
        self.contextDetector = contextDetector
    }

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        let focusContext = contextDetector.focusedAppContext()

        guard AXIsProcessTrusted() else {
            return nil
        }
        guard let focused = focusedElement() else {
            return nil
        }

        let selectedRange = selectedTextRange(for: focused)
        if let selectedRange, selectedRange.length <= 0 {
            // 某些 App 会在无选区时残留 AXSelectedText 的旧值；只要 range=0 就视为无选中。
            return nil
        }

        if
            let selectedRange,
            selectedRange.length > 0,
            let selectedText = stringAttribute(kAXSelectedTextAttribute, on: focused)
        {
            let normalized = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return FocusedSelectionSnapshot(
                    focusContext: focusContext,
                    selectedText: normalized
                )
            }
        }

        guard
            let selectedRange,
            selectedRange.length > 0,
            let value = stringAttribute(kAXValueAttribute, on: focused)
        else {
            return nil
        }

        let text = value as NSString
        let safeLocation = max(0, min(selectedRange.location, text.length))
        let safeLength = max(0, min(selectedRange.length, text.length - safeLocation))
        let nsRange = NSRange(location: safeLocation, length: safeLength)
        guard nsRange.length > 0 else {
            return nil
        }
        let selectedText = text.substring(with: nsRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else {
            return nil
        }
        return FocusedSelectionSnapshot(
            focusContext: focusContext,
            selectedText: selectedText
        )
    }

    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        if let snapshot = currentSelectionSnapshot() {
            return snapshot
        }
        return await captureSelectionSnapshotViaCopyFallback()
    }

    func captureSelectionSnapshot(preferredTarget: WritebackTargetSnapshot?) async -> FocusedSelectionSnapshot? {
        guard let preferredTarget else {
            return await captureSelectionSnapshot()
        }

        _ = await activatePreferredTargetIfNeeded(preferredTarget)

        if
            let snapshot = currentSelectionSnapshot(),
            snapshot.focusContext.bundleID == preferredTarget.bundleID,
            !snapshot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return snapshot
        }

        let targetProcessIdentifier = resolveTargetApplication(preferredTarget)?.processIdentifier
            ?? preferredTarget.processIdentifier
        return await captureSelectionSnapshotViaCopyFallback(targetProcessIdentifier: targetProcessIdentifier)
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TextOutputError.emptyText
        }
        let writeStartedAt = Date()
        let prefersPasteFirst = prefersPasteFallbackFirst(for: request)
        let isStreamingChunk = request.writeMode == .streamingChunk

        if let preferredTarget = request.preferredTarget {
            logger.log(
                "[write] preferred-target app=\(preferredTarget.appName) bundle=\(preferredTarget.bundleID) pid=\(preferredTarget.processIdentifier ?? -1)"
            )
        } else {
            logger.log("[write] preferred-target none")
        }

        // Final delivery keeps the output in clipboard for follow-up use. Streaming chunks
        // should not leave half-finished text there.
        let didPersistToClipboard =
            request.writeMode == .finalDelivery
            ? persistToClipboard(trimmedText)
            : true

        let preferredTargetReachable = await activatePreferredTargetIfNeeded(request.preferredTarget)

        let resolvedFocusContext = await resolvedEditableFocusContext(
            preferredTarget: request.preferredTarget,
            fallback: request.focusContext
        )
        let startLine = "[write] app=\(resolvedFocusContext.appName) bundle=\(resolvedFocusContext.bundleID) op=\(request.operation)"
        logger.log(startLine)

        let externalTargetReady = await shouldAttemptExternalTargetWrite(
            preferredTarget: request.preferredTarget,
            resolvedFocusContext: resolvedFocusContext,
            fallbackFocusContext: request.focusContext,
            preferredTargetReachable: preferredTargetReachable
        )
        let hasPreferredTarget = request.preferredTarget != nil
        let shouldAttemptEditorWrite =
            resolvedFocusContext.hasEditableTarget
            || externalTargetReady
            || (!hasPreferredTarget && request.focusContext.hasEditableTarget)

        guard shouldAttemptEditorWrite else {
            if isStreamingChunk {
                throw TextOutputError.noEditableTarget
            }
            if shouldAttemptBestEffortPasteWithoutEditableTarget(
                request: request,
                resolvedFocusContext: resolvedFocusContext
            ) {
                do {
                    let fallbackStartedAt = Date()
                    let targetProcessIdentifier = resolvedTargetProcessIdentifier(
                        preferredTarget: request.preferredTarget,
                        resolvedFocusContext: resolvedFocusContext,
                        fallbackFocusContext: request.focusContext
                    )
                    try await performPasteFallback(
                        text: request.text,
                        targetProcessIdentifier: targetProcessIdentifier,
                        restoreClipboardAfterPaste: request.writeMode == .streamingChunk
                    )
                    let result = TextOutputResult(
                        appName: resolvedFocusContext.appName,
                        bundleID: resolvedFocusContext.bundleID,
                        path: .pasteFallbackCommandV,
                        usedFallback: true,
                        didInsertIntoEditor: true,
                        operation: request.operation
                    )
                    let fallbackMs = elapsedMilliseconds(since: fallbackStartedAt)
                    let totalMs = elapsedMilliseconds(since: writeStartedAt)
                    logger.log("[write] no-editable-target fallback-success path=\(result.path.rawValue) fallback_ms=\(fallbackMs) total_ms=\(totalMs)")
                    return result
                } catch {
                    logger.log("[write] no-editable-target fallback-failed reason=\(error.localizedDescription)")
                }
            }
            if !didPersistToClipboard {
                throw TextOutputError.pasteboardUnavailable
            }
            logger.log("[write] no-editable-target hard-fail app=\(resolvedFocusContext.appName) bundle=\(resolvedFocusContext.bundleID)")
            throw TextOutputError.noEditableTarget
        }

        if prefersPasteFirst, !isStreamingChunk {
            do {
                let fallbackStartedAt = Date()
                let targetProcessIdentifier = resolvedTargetProcessIdentifier(
                    preferredTarget: request.preferredTarget,
                    resolvedFocusContext: resolvedFocusContext,
                    fallbackFocusContext: request.focusContext
                )
                try await performPasteFallback(
                    text: request.text,
                    targetProcessIdentifier: targetProcessIdentifier,
                    restoreClipboardAfterPaste: request.writeMode == .streamingChunk
                )
                let result = TextOutputResult(
                    appName: resolvedFocusContext.appName,
                    bundleID: resolvedFocusContext.bundleID,
                    path: .pasteFallbackCommandV,
                    usedFallback: true,
                    didInsertIntoEditor: true,
                    operation: request.operation
                )
                let fallbackMs = elapsedMilliseconds(since: fallbackStartedAt)
                let totalMs = elapsedMilliseconds(since: writeStartedAt)
                logger.log("[write] paste-first-success path=\(result.path.rawValue) fallback_ms=\(fallbackMs) total_ms=\(totalMs)")
                return result
            } catch {
                logger.log("[write] paste-first-failed reason=\(error.localizedDescription)")
            }
        }

        do {
            let axStartedAt = Date()
            try performAccessibilityPath(text: request.text, operation: request.operation)
            let result = TextOutputResult(
                appName: resolvedFocusContext.appName,
                bundleID: resolvedFocusContext.bundleID,
                path: .accessibilitySelectionReplacement,
                usedFallback: false,
                didInsertIntoEditor: true,
                operation: request.operation
            )
            let totalMs = elapsedMilliseconds(since: writeStartedAt)
            let axMs = elapsedMilliseconds(since: axStartedAt)
            logger.log("[write] success path=\(result.path.rawValue) ax_ms=\(axMs) total_ms=\(totalMs)")
            return result
        } catch {
            let primaryReason = error.localizedDescription
            let axMs = elapsedMilliseconds(since: writeStartedAt)
            logger.log("[write] primary-failed reason=\(primaryReason) ax_ms=\(axMs)")

            if isStreamingChunk {
                throw error
            }

            do {
                let fallbackStartedAt = Date()
                let targetProcessIdentifier = resolvedTargetProcessIdentifier(
                    preferredTarget: request.preferredTarget,
                    resolvedFocusContext: resolvedFocusContext,
                    fallbackFocusContext: request.focusContext
                )
                try await performPasteFallback(
                    text: request.text,
                    targetProcessIdentifier: targetProcessIdentifier,
                    restoreClipboardAfterPaste: request.writeMode == .streamingChunk
                )
                let result = TextOutputResult(
                    appName: resolvedFocusContext.appName,
                    bundleID: resolvedFocusContext.bundleID,
                    path: .pasteFallbackCommandV,
                    usedFallback: true,
                    didInsertIntoEditor: true,
                    operation: request.operation
                )
                let fallbackMs = elapsedMilliseconds(since: fallbackStartedAt)
                let totalMs = elapsedMilliseconds(since: writeStartedAt)
                logger.log("[write] fallback-success path=\(result.path.rawValue) fallback_ms=\(fallbackMs) total_ms=\(totalMs)")
                return result
            } catch {
                let totalMs = elapsedMilliseconds(since: writeStartedAt)
                logger.log("[write] fallback-failed reason=\(error.localizedDescription) total_ms=\(totalMs)")
                throw TextOutputError.fallbackFailed(primaryReason: primaryReason)
            }
        }
    }

    private func shouldAttemptBestEffortPasteWithoutEditableTarget(
        request: TextOutputRequest,
        resolvedFocusContext: FocusedAppContext
    ) -> Bool {
        if let preferredTarget = request.preferredTarget {
            return resolveTargetApplication(preferredTarget) != nil
        }

        if isExternalApplicationBundle(request.focusContext.bundleID) {
            if currentFrontmostApplication()?.bundleIdentifier == request.focusContext.bundleID {
                return true
            }
            if !runningApplications(withBundleIdentifier: request.focusContext.bundleID).isEmpty {
                return true
            }
        }

        guard
            request.focusContext.hasEditableTarget,
            isExternalApplicationBundle(request.focusContext.bundleID)
        else {
            return false
        }

        if currentFrontmostApplication()?.bundleIdentifier == request.focusContext.bundleID {
            return true
        }

        return !runningApplications(withBundleIdentifier: request.focusContext.bundleID).isEmpty
            || resolvedFocusContext.bundleID == request.focusContext.bundleID
    }

    func performAccessibilityPath(
        text: String,
        operation: TextOutputOperation
    ) throws {
        guard AXIsProcessTrusted() else {
            throw TextOutputError.accessibilityPermissionMissing
        }
        guard let focused = focusedElement() else {
            throw TextOutputError.noFocusedElement
        }

        if !isEditable(element: focused) {
            throw TextOutputError.noEditableTarget
        }

        switch operation {
        case .insertText, .replaceSelectedText:
            try replaceSelectedRange(in: focused, with: text)
        }
    }

    func replaceSelectedRange(in element: AXUIElement, with text: String) throws {
        let selectedTextStatus = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedTextStatus == .success {
            return
        }

        guard let originalValue = stringAttribute(kAXValueAttribute, on: element) else {
            throw TextOutputError.accessibilityPathFailed(reason: "无法写入选区文本或更新当前焦点内容。")
        }

        let selectedRange = selectedTextRange(for: element) ?? CFRange(location: originalValue.utf16.count, length: 0)
        let originalNSString = originalValue as NSString
        let safeLocation = max(0, min(selectedRange.location, originalNSString.length))
        let safeLength = max(0, min(selectedRange.length, originalNSString.length - safeLocation))
        let nsRange = NSRange(location: safeLocation, length: safeLength)
        let updatedValue = originalNSString.replacingCharacters(in: nsRange, with: text)

        let setValueStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueStatus == .success else {
            throw TextOutputError.accessibilityPathFailed(reason: "无法更新当前焦点内容。")
        }

        var cursorRange = CFRange(
            location: safeLocation + text.utf16.count,
            length: 0
        )
        if let rangeValue = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
    }

    func shouldAttemptExternalTargetWrite(
        preferredTarget: WritebackTargetSnapshot?,
        resolvedFocusContext: FocusedAppContext,
        fallbackFocusContext: FocusedAppContext,
        preferredTargetReachable: Bool
    ) async -> Bool {
        if preferredTarget != nil {
            return preferredTargetReachable
        }

        guard let bundleID = candidateExternalBundleID(
            resolvedFocusContext: resolvedFocusContext,
            fallbackFocusContext: fallbackFocusContext
        ) else {
            return false
        }

        if currentFrontmostApplication()?.bundleIdentifier == bundleID {
            return true
        }

        return await activateApplication(bundleID: bundleID)
    }

    func performPasteFallback(text: String) async throws {
        try await performPasteFallback(
            text: text,
            targetProcessIdentifier: nil
        )
    }

    func performPasteFallback(
        text: String,
        targetProcessIdentifier: pid_t?
    ) async throws {
        try await performPasteFallback(
            text: text,
            targetProcessIdentifier: targetProcessIdentifier,
            restoreClipboardAfterPaste: false
        )
    }

    func performPasteFallback(
        text: String,
        targetProcessIdentifier: pid_t?,
        restoreClipboardAfterPaste: Bool
    ) async throws {
        let pasteboard = NSPasteboard.general
        let clipboardSnapshot = restoreClipboardAfterPaste ? pasteboardSnapshot(pasteboard) : nil

        guard persistToClipboard(text) else {
            throw TextOutputError.pasteboardUnavailable
        }

        func restoreClipboardIfNeeded() {
            if let clipboardSnapshot {
                restorePasteboard(clipboardSnapshot, to: pasteboard)
            }
        }

        // Prefer PID-targeted injection when we know which app should receive Cmd+V.
        // Global injection is a fallback only; some apps (notably Electron/WebView surfaces)
        // can miss global events more often than PID-targeted posting.
        if let targetProcessIdentifier, targetProcessIdentifier > 0 {
            logger.log("[write] paste-fallback target-pid=\(targetProcessIdentifier)")
        } else {
            let frontmostBundleID = currentFrontmostApplication()?.bundleIdentifier
            logger.log("[write] paste-fallback global bundle=\(frontmostBundleID ?? "unknown")")
        }

        do {
            try triggerCommandV(
                targetProcessIdentifier: targetProcessIdentifier
            )
            try await Task.sleep(nanoseconds: 80_000_000)
            restoreClipboardIfNeeded()
        } catch {
            restoreClipboardIfNeeded()
            throw error
        }
    }

    @discardableResult
    func persistToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func triggerCommandV(targetProcessIdentifier: pid_t?) throws {
        if
            let targetProcessIdentifier,
            targetProcessIdentifier > 0
        {
            do {
                try postCommandV(to: targetProcessIdentifier)
                return
            } catch {
                logger.log("[write] target-paste-failed pid=\(targetProcessIdentifier) reason=\(error.localizedDescription)")
            }
        }

        try postGlobalCommandV()
    }

    func triggerCommandC(targetProcessIdentifier: pid_t?) throws {
        if
            let targetProcessIdentifier,
            targetProcessIdentifier > 0
        {
            do {
                try postCommandKey("c", targetProcessIdentifier: targetProcessIdentifier, postToPID: true)
                return
            } catch {
                logger.log("[selection] target-copy-failed pid=\(targetProcessIdentifier) reason=\(error.localizedDescription)")
            }
        }

        try postCommandKey("c", targetProcessIdentifier: nil, postToPID: false)
    }

    func postCommandV(to processIdentifier: pid_t) throws {
        try postCommandKey("v", targetProcessIdentifier: processIdentifier, postToPID: true)
    }

    func postGlobalCommandV() throws {
        try postCommandKey("v", targetProcessIdentifier: nil, postToPID: false)
    }

    private func postCommandKey(
        _ key: Character,
        targetProcessIdentifier: pid_t?,
        postToPID: Bool
    ) throws {
        let virtualKey: CGKeyCode
        switch String(key).lowercased() {
        case "c":
            virtualKey = CGKeyCode(kVK_ANSI_C)
        case "v":
            virtualKey = CGKeyCode(kVK_ANSI_V)
        default:
            throw TextOutputError.pasteShortcutInjectionFailed
        }

        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: virtualKey,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: virtualKey,
                keyDown: false
            )
        else {
            throw TextOutputError.pasteShortcutInjectionFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if postToPID, let targetProcessIdentifier, targetProcessIdentifier > 0 {
            keyDown.postToPid(targetProcessIdentifier)
            keyUp.postToPid(targetProcessIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func captureSelectionSnapshotViaCopyFallback(
        targetProcessIdentifier: pid_t? = nil
    ) async -> FocusedSelectionSnapshot? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let focusContext = contextDetector.focusedAppContext()
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboardSnapshot(pasteboard)
        let originalChangeCount = pasteboard.changeCount

        defer {
            restorePasteboard(snapshot, to: pasteboard)
        }

        // Prefer PID-targeted injection when possible. We still fall back to global posting
        // internally if PID posting fails.
        let copyTargetProcessIdentifier: pid_t? = targetProcessIdentifier
            ?? currentFrontmostApplication()?.processIdentifier

        do {
            try triggerCommandC(targetProcessIdentifier: copyTargetProcessIdentifier)
        } catch {
            logger.log("[selection] copy-fallback-trigger-failed reason=\(error.localizedDescription)")
            return nil
        }

        guard let copiedText = await waitForCopiedString(after: originalChangeCount, pasteboard: pasteboard) else {
            logger.log("[selection] copy-fallback-no-text")
            return nil
        }

        return FocusedSelectionSnapshot(
            focusContext: focusContext,
            selectedText: copiedText
        )
    }

    private func waitForCopiedString(
        after originalChangeCount: Int,
        pasteboard: NSPasteboard,
        timeoutNanoseconds: UInt64 = 420_000_000
    ) async -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if pasteboard.changeCount != originalChangeCount {
                let copiedText = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let copiedText, !copiedText.isEmpty {
                    return copiedText
                }
                return nil
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return nil
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func pasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            Dictionary<NSPasteboard.PasteboardType, Data>(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            })
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return
        }

        let restoredItems = snapshot.items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }

    func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success else {
            return nil
        }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    func isEditable(element: AXUIElement) -> Bool {
        if let editable = boolAttribute("AXEditable", on: element), editable {
            return true
        }

        if let role = stringAttribute(kAXRoleAttribute, on: element) {
            let editableRoles = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                "AXSearchField",
                kAXComboBoxRole as String
            ]
            if editableRoles.contains(role) {
                return true
            }
        }

        return hasAttribute(kAXSelectedTextRangeAttribute, on: element)
    }

    func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success, let axValue = value else {
            return nil
        }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        let ok = AXValueGetValue(
            unsafeBitCast(axValue, to: AXValue.self),
            .cfRange,
            &range
        )
        return ok ? range : nil
    }

    func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    func boolAttribute(_ attribute: String, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? Bool
    }

    func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let names else {
            return false
        }
        let allNames = names as [AnyObject]
        return allNames.contains { ($0 as? String) == attribute }
    }

    func currentFrontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func runningApplications(withBundleIdentifier bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    func activateApplication(_ application: NSRunningApplication) -> Bool {
        application.activate(options: [.activateAllWindows])
    }

    func activationPauseNanoseconds() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func focusRetryIntervalNanoseconds() async {
        try? await Task.sleep(nanoseconds: 70_000_000)
    }

    func resolvedFocusContext(
        preferredTarget: WritebackTargetSnapshot?,
        fallback: FocusedAppContext
    ) -> FocusedAppContext {
        let current = contextDetector.focusedAppContext()
        let selfBundleID = Bundle.main.bundleIdentifier

        if
            let preferredTarget,
            current.bundleID == preferredTarget.bundleID
        {
            return current
        }

        if current.bundleID != selfBundleID {
            return current
        }

        if let preferredTarget {
            return FocusedAppContext(
                appName: preferredTarget.appName,
                bundleID: preferredTarget.bundleID,
                focusedRole: fallback.focusedRole,
                hasEditableTarget: false,
                strategyHint: fallback.strategyHint
            )
        }

        return fallback
    }

    func activatePreferredTargetIfNeeded(_ preferredTarget: WritebackTargetSnapshot?) async -> Bool {
        guard let preferredTarget else {
            return true
        }

        if
            let frontmost = currentFrontmostApplication(),
            frontmost.bundleIdentifier == preferredTarget.bundleID,
            preferredTarget.processIdentifier == nil || frontmost.processIdentifier == preferredTarget.processIdentifier
        {
            return true
        }

        guard
            let targetApplication = resolveTargetApplication(preferredTarget)
        else {
            logger.log("[write] target-missing bundle=\(preferredTarget.bundleID)")
            return false
        }

        let activated = activateApplication(targetApplication)
        logger.log("[write] target-activate bundle=\(preferredTarget.bundleID) ok=\(activated)")
        let reached = activated
            ? await waitUntilFrontmost(
                bundleID: preferredTarget.bundleID,
                processIdentifier: targetApplication.processIdentifier
            )
            : false
        logger.log("[write] target-frontmost bundle=\(preferredTarget.bundleID) pid=\(targetApplication.processIdentifier) ok=\(reached)")
        return reached
    }

    func activateApplication(bundleID: String) async -> Bool {
        guard
            let targetApplication = runningApplications(withBundleIdentifier: bundleID).first
        else {
            logger.log("[write] target-missing bundle=\(bundleID)")
            return false
        }

        let activated = activateApplication(targetApplication)
        logger.log("[write] target-activate bundle=\(bundleID) ok=\(activated)")
        let reached = activated
            ? await waitUntilFrontmost(
                bundleID: bundleID,
                processIdentifier: targetApplication.processIdentifier
            )
            : false
        logger.log("[write] target-frontmost bundle=\(bundleID) pid=\(targetApplication.processIdentifier) ok=\(reached)")
        return reached
    }

    func resolveTargetApplication(_ preferredTarget: WritebackTargetSnapshot) -> NSRunningApplication? {
        let candidates = runningApplications(withBundleIdentifier: preferredTarget.bundleID)
        if let processIdentifier = preferredTarget.processIdentifier {
            return candidates.first(where: { $0.processIdentifier == processIdentifier }) ?? candidates.first
        }
        return candidates.first
    }

    func resolvedEditableFocusContext(
        preferredTarget: WritebackTargetSnapshot?,
        fallback: FocusedAppContext
    ) async -> FocusedAppContext {
        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let context = resolvedFocusContext(
                preferredTarget: preferredTarget,
                fallback: fallback
            )
            if context.hasEditableTarget {
                return context
            }
            if attempt < maxAttempts {
                await focusRetryIntervalNanoseconds()
            }
        }
        return resolvedFocusContext(
            preferredTarget: preferredTarget,
            fallback: fallback
        )
    }

    private func candidateExternalBundleID(
        resolvedFocusContext: FocusedAppContext,
        fallbackFocusContext: FocusedAppContext
    ) -> String? {
        if isExternalApplicationBundle(resolvedFocusContext.bundleID) {
            return resolvedFocusContext.bundleID
        }
        if isExternalApplicationBundle(fallbackFocusContext.bundleID) {
            return fallbackFocusContext.bundleID
        }
        return nil
    }

    private func isExternalApplicationBundle(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID != "unknown.bundle" else {
            return false
        }
        let selfBundleID = Bundle.main.bundleIdentifier
        return bundleID != selfBundleID
    }

    private func prefersPasteFallbackFirst(for request: TextOutputRequest) -> Bool {
        if request.focusContext.bundleID == "com.openai.codex" {
            return true
        }
        if request.preferredTarget?.bundleID == "com.openai.codex" {
            return true
        }
        return false
    }

    private func prefersGlobalShortcutInjection(bundleID: String?) -> Bool {
        bundleID == "com.openai.codex"
    }

    func resolvedTargetProcessIdentifier(
        preferredTarget: WritebackTargetSnapshot?,
        resolvedFocusContext: FocusedAppContext,
        fallbackFocusContext: FocusedAppContext
    ) -> pid_t? {
        if let processIdentifier = preferredTarget?.processIdentifier {
            return processIdentifier
        }

        if
            let preferredTarget,
            let targetApplication = resolveTargetApplication(preferredTarget)
        {
            return targetApplication.processIdentifier
        }

        if
            let bundleID = candidateExternalBundleID(
                resolvedFocusContext: resolvedFocusContext,
                fallbackFocusContext: fallbackFocusContext
            ),
            let targetApplication = runningApplications(withBundleIdentifier: bundleID).first
        {
            return targetApplication.processIdentifier
        }

        if let frontmost = currentFrontmostApplication() {
            return frontmost.processIdentifier
        }

        return nil
    }

    func prepareForWrite(
        preferredTarget: WritebackTargetSnapshot?,
        fallbackFocusContext: FocusedAppContext
    ) async {
        if let preferredTarget {
            _ = await activatePreferredTargetIfNeeded(preferredTarget)
            _ = await resolvedEditableFocusContext(
                preferredTarget: preferredTarget,
                fallback: fallbackFocusContext
            )
            return
        }

        if
            let bundleID = candidateExternalBundleID(
                resolvedFocusContext: fallbackFocusContext,
                fallbackFocusContext: fallbackFocusContext
            )
        {
            _ = await activateApplication(bundleID: bundleID)
        }
    }

    private func waitUntilFrontmost(
        bundleID: String,
        processIdentifier: pid_t
    ) async -> Bool {
        let attempts = 5
        for attempt in 1...attempts {
            let frontmost = currentFrontmostApplication()
            let reached = frontmost?.processIdentifier == processIdentifier
                || frontmost?.bundleIdentifier == bundleID
            if reached {
                return true
            }
            if attempt < attempts {
                await activationPauseNanoseconds()
            }
        }
        return false
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}

final class TextOutputLogger {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        diagnosticsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = diagnosticsDirectory.appendingPathComponent(
            "text-output.log",
            isDirectory: false
        )
    }

    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(Self.redactSensitiveText(message))\n"
        append(line)
    }

    private static func redactSensitiveText(_ text: String) -> String {
        var output = text
        output = replaceRegex(
            pattern: #"(?i)(Authorization\s*:\s*Bearer\s+)[A-Za-z0-9._\-]+"#,
            template: "$1[REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#,
            template: "Bearer [REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bsk-[A-Za-z0-9]{10,}\b"#,
            template: "sk-[REDACTED]",
            in: output
        )
        return output
    }

    private static func replaceRegex(
        pattern: String,
        template: String,
        in text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private func append(_ value: String) {
        let data = Data(value.utf8)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
