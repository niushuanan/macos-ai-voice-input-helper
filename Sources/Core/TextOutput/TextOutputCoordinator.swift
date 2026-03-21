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
}

struct FocusedSelectionSnapshot: Equatable {
    let focusContext: FocusedAppContext
    let selectedText: String
}

enum TextOutputPath: String, Equatable {
    case accessibilitySelectionReplacement
    case pasteFallbackCommandV
}

struct TextOutputResult: Equatable {
    let appName: String
    let bundleID: String
    let path: TextOutputPath
    let usedFallback: Bool
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
final class AccessibilityTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "主路径：AX 直写；兜底：剪贴板 + Command+V。"

    private let logger: TextOutputLogger

    init(logger: TextOutputLogger) {
        self.logger = logger
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

        let startLine = "[write] app=\(request.focusContext.appName) bundle=\(request.focusContext.bundleID) op=\(request.operation)"
        logger.log(startLine)

        do {
            try performAccessibilityPath(text: request.text, operation: request.operation)
            let result = TextOutputResult(
                appName: request.focusContext.appName,
                bundleID: request.focusContext.bundleID,
                path: .accessibilitySelectionReplacement,
                usedFallback: false,
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
                    appName: request.focusContext.appName,
                    bundleID: request.focusContext.bundleID,
                    path: .pasteFallbackCommandV,
                    usedFallback: true,
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

    private func performAccessibilityPath(
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

    private func replaceSelectedRange(in element: AXUIElement, with text: String) throws {
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

    private func performPasteFallback(text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextOutputError.pasteboardUnavailable
        }

        do {
            try triggerCommandV()
            try await Task.sleep(nanoseconds: 220_000_000)
            snapshot.restore(to: pasteboard)
        } catch {
            snapshot.restore(to: pasteboard)
            throw error
        }
    }

    private func triggerCommandV() throws {
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

    private func focusedElement() -> AXUIElement? {
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

    private func isEditable(element: AXUIElement) -> Bool {
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

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
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

    private func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? Bool
    }

    private func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let names else {
            return false
        }
        let allNames = names as [AnyObject]
        return allNames.contains { ($0 as? String) == attribute }
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

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let itemData: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }
        return PasteboardSnapshot(items: itemData)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoreItems: [NSPasteboardItem] = items.compactMap { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoreItems.isEmpty {
            pasteboard.writeObjects(restoreItems)
        }
    }
}
