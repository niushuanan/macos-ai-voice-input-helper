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
            return "No text available for insertion."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for direct insertion."
        case .noFocusedElement:
            return "No focused input target found."
        case .noEditableTarget:
            return "Focused target is not editable."
        case let .accessibilityPathFailed(reason):
            return "Direct insertion failed: \(reason)"
        case .pasteboardUnavailable:
            return "Pasteboard is unavailable for fallback."
        case .pasteShortcutInjectionFailed:
            return "Could not trigger paste shortcut for fallback."
        case let .fallbackFailed(primaryReason):
            return "Direct path and fallback both failed. Direct path reason: \(primaryReason)"
        }
    }
}

protocol TextOutputCoordinator {
    var insertionStrategy: String { get }
    func write(request: TextOutputRequest) async throws -> TextOutputResult
}

@MainActor
final class AccessibilityTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "Primary: AX direct insertion. Fallback: pasteboard + Command+V."

    private let logger: TextOutputLogger

    init(logger: TextOutputLogger) {
        self.logger = logger
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
                throw TextOutputError.accessibilityPathFailed(reason: "Could not set selected text.")
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
            throw TextOutputError.accessibilityPathFailed(reason: "Could not update focused value.")
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
        let line = "\(formatter.string(from: Date())) \(message)\n"
        append(line)
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
        try? handle.seekToEnd()
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
