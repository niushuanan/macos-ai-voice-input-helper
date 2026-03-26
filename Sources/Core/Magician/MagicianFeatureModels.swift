import AppKit
import EventKit
import Foundation

enum MagicianMailCapability {
    static var composeEmailServiceAvailable: Bool {
        NSSharingService(named: .composeEmail) != nil
    }

    static var mailtoAvailable: Bool {
        guard let probeURL = URL(string: "mailto:pulsetype@example.com") else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(toOpen: probeURL) != nil
    }

    static var mailAppAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
            || FileManager.default.fileExists(atPath: "/System/Applications/Mail.app")
    }
}

enum MagicianNotesCapability {
    static var notesAppAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") != nil
            || FileManager.default.fileExists(atPath: "/System/Applications/Notes.app")
    }
}

struct MagicianCreateNoteShortcutSupport {
    static let shortcutsExecutablePath = "/usr/bin/shortcuts"
    static let shortcutNameDefaultsKey = "magician.shortcuts.create_note.name.v1"
    static let defaultShortcutName = "PulseType-写入备忘录"

    let defaults: UserDefaults
    let fileManager: FileManager

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var shortcutName: String {
        let customized = defaults.string(forKey: Self.shortcutNameDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return customized.isEmpty ? Self.defaultShortcutName : customized
    }

    var cliAvailable: Bool {
        fileManager.isExecutableFile(atPath: Self.shortcutsExecutablePath)
    }

    func hasShortcut(named customName: String? = nil) -> Bool {
        guard cliAvailable else {
            return false
        }
        let targetName = (customName ?? shortcutName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            return false
        }

        guard let listResult = listShortcuts(), listResult.exitCode == 0 else {
            return false
        }

        let lines = listResult.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.contains { $0.caseInsensitiveCompare(targetName) == .orderedSame }
    }

    private func listShortcuts() -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.shortcutsExecutablePath)
        process.arguments = ["list"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        return (
            exitCode: process.terminationStatus,
            output: outputText
        )
    }
}

enum MagicianFeatureID: String, CaseIterable, Codable, Identifiable {
    case textTransform = "text_transform"
    case webSearch = "web_search"
    case createEvent = "create_event"
    case createNote = "create_note"
    case composeEmailDraft = "compose_email_draft"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textTransform:
            return "文字处理"
        case .webSearch:
            return "快速搜索"
        case .createEvent:
            return "一键建日程"
        case .createNote:
            return "写入备忘录"
        case .composeEmailDraft:
            return "邮件草稿"
        }
    }

    var summaryLine: String {
        switch self {
        case .textTransform:
            return "把选中内容改成你想要的表达。"
        case .webSearch:
            return "把选中内容直接放进 Chrome 的 Google 搜索。"
        case .createEvent:
            return "从选中内容里识别时间和主题，直接加入日历。"
        case .createNote:
            return "把选中内容快速记到备忘录。"
        case .composeEmailDraft:
            return "把选中内容整理成邮件草稿，并打开邮件 App。"
        }
    }

    var boundaryLine: String {
        switch self {
        case .textTransform:
            return "仅作用于当前选中内容。"
        case .webSearch:
            return "只打开结果页，不自动浏览网页。"
        case .createEvent:
            return "信息不完整时按默认规则自动推断。"
        case .createNote:
            return "只新增，不改已有笔记。"
        case .composeEmailDraft:
            return "只生成草稿，不自动发送。"
        }
    }

    var sampleCommand: String {
        switch self {
        case .textTransform:
            return "翻成日语"
        case .webSearch:
            return "帮我搜索一下"
        case .createEvent:
            return "周五下午和产品开评审会"
        case .createNote:
            return "记到备忘录"
        case .composeEmailDraft:
            return "整理成邮件草稿"
        }
    }

    var symbolName: String {
        switch self {
        case .textTransform:
            return "text.bubble"
        case .webSearch:
            return "magnifyingglass"
        case .createEvent:
            return "calendar"
        case .createNote:
            return "note.text"
        case .composeEmailDraft:
            return "envelope"
        }
    }
}

struct MagicianFeatureDescriptor: Identifiable, Equatable {
    let id: MagicianFeatureID
    let name: String
    let summary: String
    let boundary: String
    let example: String
    let symbolName: String

    static let all: [MagicianFeatureDescriptor] = MagicianFeatureID.allCases.map { feature in
        MagicianFeatureDescriptor(
            id: feature,
            name: feature.displayName,
            summary: feature.summaryLine,
            boundary: feature.boundaryLine,
            example: feature.sampleCommand,
            symbolName: feature.symbolName
        )
    }
}

enum MagicianFeatureStatus: String, Equatable {
    case notEnabled
    case needsPermission
    case enabled

    var labelText: String {
        switch self {
        case .notEnabled:
            return "未开启"
        case .needsPermission:
            return "需权限"
        case .enabled:
            return "已开启"
        }
    }
}

struct MagicianDependencySnapshot: Equatable {
    let accessibilityState: PermissionState
    let eventAuthorizationStatus: EKAuthorizationStatus
    let shortcutsCLIAvailable: Bool
    let createNoteShortcutName: String
    let createNoteShortcutExists: Bool
    let notesAppAvailable: Bool
    let composeEmailAvailable: Bool
    let mailtoAvailable: Bool
    let mailAppAvailable: Bool
}
