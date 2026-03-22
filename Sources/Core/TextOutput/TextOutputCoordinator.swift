import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Foundation

enum TextOutputOperation: Equatable {
    case insertText
    case replaceSelectedText
}

struct TextOutputRequest: Equatable {
    let text: String
    let operation: TextOutputOperation
    let focusContext: FocusedAppContext
    let preferredTarget: WritebackTargetSnapshot?

    init(
        text: String,
        operation: TextOutputOperation,
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot? = nil
    ) {
        self.text = text
        self.operation = operation
        self.focusContext = focusContext
        self.preferredTarget = preferredTarget
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
    func write(request: TextOutputRequest) async throws -> TextOutputResult
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
        let app = NSWorkspace.shared.frontmostApplication
        let focusContext = FocusedAppContext(
            appName: app?.localizedName ?? "未知应用",
            bundleID: app?.bundleIdentifier ?? "unknown.bundle",
            focusedRole: nil,
            hasEditableTarget: true,
            strategyHint: "AX 选区路径"
        )

        guard AXIsProcessTrusted() else {
            return nil
        }
        guard let focused = focusedElement() else {
            return nil
        }

        if let selectedText = stringAttribute(kAXSelectedTextAttribute, on: focused) {
            let normalized = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return FocusedSelectionSnapshot(
                    focusContext: focusContext,
                    selectedText: selectedText
                )
            }
        }

        guard
            let selectedRange = selectedTextRange(for: focused),
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

        return FocusedSelectionSnapshot(
            focusContext: focusContext,
            selectedText: text.substring(with: nsRange)
        )
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TextOutputError.emptyText
        }

        // Keep the final text in clipboard so user can reuse it after writeback.
        let didPersistToClipboard = persistToClipboard(trimmedText)

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
            if !didPersistToClipboard {
                throw TextOutputError.pasteboardUnavailable
            }
            logger.log("[write] no-editable-target app=\(resolvedFocusContext.appName) bundle=\(resolvedFocusContext.bundleID)")
            return TextOutputResult(
                appName: resolvedFocusContext.appName,
                bundleID: resolvedFocusContext.bundleID,
                path: .clipboardOnly,
                usedFallback: false,
                didInsertIntoEditor: false,
                operation: request.operation
            )
        }

        do {
            try performAccessibilityPath(text: request.text, operation: request.operation)
            let result = TextOutputResult(
                appName: resolvedFocusContext.appName,
                bundleID: resolvedFocusContext.bundleID,
                path: .accessibilitySelectionReplacement,
                usedFallback: false,
                didInsertIntoEditor: true,
                operation: request.operation
            )
            logger.log("[write] success path=\(result.path.rawValue)")
            return result
        } catch {
            let primaryReason = error.localizedDescription
            logger.log("[write] primary-failed reason=\(primaryReason)")

            do {
                try await performPasteFallback(text: request.text)
                let result = TextOutputResult(
                    appName: resolvedFocusContext.appName,
                    bundleID: resolvedFocusContext.bundleID,
                    path: .pasteFallbackCommandV,
                    usedFallback: true,
                    didInsertIntoEditor: true,
                    operation: request.operation
                )
                logger.log("[write] fallback-success path=\(result.path.rawValue)")
                return result
            } catch {
                logger.log("[write] fallback-failed reason=\(error.localizedDescription)")
                throw TextOutputError.fallbackFailed(primaryReason: primaryReason)
            }
        }
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
        guard let originalValue = stringAttribute(kAXValueAttribute, on: element) else {
            let status = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            guard status == .success else {
                throw TextOutputError.accessibilityPathFailed(reason: "无法直接写入选中文本。")
            }
            return
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
        guard persistToClipboard(text) else {
            throw TextOutputError.pasteboardUnavailable
        }

        try triggerCommandV()
        try await Task.sleep(nanoseconds: 220_000_000)
    }

    @discardableResult
    func persistToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func triggerCommandV() throws {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
        else {
            throw TextOutputError.pasteShortcutInjectionFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
        try? await Task.sleep(nanoseconds: 320_000_000)
    }

    func focusRetryIntervalNanoseconds() async {
        try? await Task.sleep(nanoseconds: 180_000_000)
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

        if currentFrontmostApplication()?.bundleIdentifier == preferredTarget.bundleID {
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
        if activated {
            await activationPauseNanoseconds()
        }
        return activated
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
        if activated {
            await activationPauseNanoseconds()
        }
        return activated
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
        let maxAttempts = 6
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
