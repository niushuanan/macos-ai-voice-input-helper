import AppKit
import ApplicationServices
import Foundation

struct FocusedAppContext: Equatable {
    let appName: String
    let bundleID: String
    let focusedRole: String?
    let hasEditableTarget: Bool
    let strategyHint: String
}

struct ContextSnapshot: Equatable {
    let focusContext: FocusedAppContext
    let rewriteAvailable: Bool
    let styleHint: String
}

protocol ContextDetector {
    func currentSnapshot() -> ContextSnapshot
    func focusedAppContext() -> FocusedAppContext
}

struct AccessibilityContextDetector: ContextDetector {
    func currentSnapshot() -> ContextSnapshot {
        let focusContext = focusedAppContext()
        return ContextSnapshot(
            focusContext: focusContext,
            rewriteAvailable: focusContext.hasEditableTarget,
            styleHint: "Adaptive"
        )
    }

    func focusedAppContext() -> FocusedAppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown App"
        let bundleID = app?.bundleIdentifier ?? "unknown.bundle"
        let focusedRole = focusedElementRole()
        let editable = hasEditableFocusedTarget()

        return FocusedAppContext(
            appName: appName,
            bundleID: bundleID,
            focusedRole: focusedRole,
            hasEditableTarget: editable,
            strategyHint: strategyHint(for: bundleID)
        )
    }

    private func focusedElementRole() -> String? {
        guard let element = focusedElement() else {
            return nil
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    private func hasEditableFocusedTarget() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        guard let element = focusedElement() else {
            return false
        }

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

        if hasAttribute(kAXSelectedTextRangeAttribute, on: element) {
            return true
        }

        return false
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
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
        let attrNames = names as [AnyObject]
        return attrNames.contains { ($0 as? String) == attribute }
    }

    private func strategyHint(for bundleID: String) -> String {
        if bundleID == "com.apple.TextEdit" || bundleID == "com.apple.Notes" {
            return "AX direct insert is usually stable."
        }
        if bundleID.contains("Xcode") || bundleID.contains("code") {
            return "AX may vary, paste fallback is often used."
        }
        if bundleID.contains("discord") || bundleID.contains("slack") {
            return "Message apps often work best with paste fallback."
        }
        return "Try AX direct path first, then paste fallback if needed."
    }
}

struct StubContextDetector: ContextDetector {
    func currentSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            focusContext: FocusedAppContext(
                appName: "Unknown App",
                bundleID: "unknown.bundle",
                focusedRole: nil,
                hasEditableTarget: true,
                strategyHint: "Try AX direct path first, then paste fallback if needed."
            ),
            rewriteAvailable: true,
            styleHint: "Adaptive"
        )
    }

    func focusedAppContext() -> FocusedAppContext {
        currentSnapshot().focusContext
    }
}
