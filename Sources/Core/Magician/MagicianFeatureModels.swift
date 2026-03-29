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

struct MagicianMailCapabilitySnapshot: Equatable {
    let composeEmailServiceAvailable: Bool
    let mailtoAvailable: Bool
    let mailAppAvailable: Bool

    static func current() -> Self {
        MagicianMailCapabilitySnapshot(
            composeEmailServiceAvailable: MagicianMailCapability.composeEmailServiceAvailable,
            mailtoAvailable: MagicianMailCapability.mailtoAvailable,
            mailAppAvailable: MagicianMailCapability.mailAppAvailable
        )
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
    case createEvent = "create_event"
    case createNote = "create_note"
    case composeEmailDraft = "compose_email_draft"
    case feishuCLI = "feishu_cli"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textTransform:
            return "文字处理"
        case .createEvent:
            return "一键建日程"
        case .createNote:
            return "写入备忘录"
        case .composeEmailDraft:
            return "邮件助手"
        case .feishuCLI:
            return "飞书 CLI"
        }
    }

    var progressTitle: String {
        switch self {
        case .textTransform:
            return "文字处理中"
        case .createEvent:
            return "建日程中"
        case .createNote:
            return "写入备忘录中"
        case .composeEmailDraft:
            return "整理邮件中"
        case .feishuCLI:
            return "执行飞书命令中"
        }
    }

    var summaryLine: String {
        switch self {
        case .textTransform:
            return "把选中内容改成你想要的表达。"
        case .createEvent:
            return "从选中内容里识别时间和主题，直接加入日历。"
        case .createNote:
            return "把选中内容快速记到备忘录。"
        case .composeEmailDraft:
            return "整理主题和正文，打开 Mail；地址明确时可直接发出。"
        case .feishuCLI:
            return "无选中也能语音下令，调用飞书 CLI 执行动作。"
        }
    }

    var boundaryLine: String {
        switch self {
        case .textTransform:
            return "仅作用于当前选中内容。"
        case .createEvent:
            return "信息不完整时按默认规则自动推断。"
        case .createNote:
            return "只新增，不改已有笔记。"
        case .composeEmailDraft:
            return "地址明确且模型判断该直接发时，会自动发送；不明确时只打开编辑窗口。"
        case .feishuCLI:
            return "仅执行飞书 CLI 允许动作；未知命令会直接拒绝并给提示。"
        }
    }

    var sampleCommand: String {
        switch self {
        case .textTransform:
            return "翻成日语"
        case .createEvent:
            return "周五下午和产品开评审会"
        case .createNote:
            return "记到备忘录"
        case .composeEmailDraft:
            return "给小庄发邮件"
        case .feishuCLI:
            return "飞书查今天议程"
        }
    }

    var symbolName: String {
        switch self {
        case .textTransform:
            return "text.bubble"
        case .createEvent:
            return "calendar"
        case .createNote:
            return "note.text"
        case .composeEmailDraft:
            return "envelope"
        case .feishuCLI:
            return "paperplane.circle"
        }
    }
}

enum MagicianPermissionScope: String, CaseIterable, Codable, Identifiable {
    case textProcessing = "text_processing"
    case feishu = "feishu"
    case appleNativeApps = "apple_native_apps"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textProcessing:
            return "文字处理"
        case .feishu:
            return "飞书"
        case .appleNativeApps:
            return "苹果原生应用"
        }
    }

    var symbolName: String {
        switch self {
        case .textProcessing:
            return "text.bubble"
        case .feishu:
            return "paperplane.circle"
        case .appleNativeApps:
            return "apple.logo"
        }
    }

    var summary: String {
        switch self {
        case .textProcessing:
            return "有选中时改写文字；无选中时可当文本命令助手。"
        case .feishu:
            return "无选中也能语音下令，走飞书 CLI 执行。"
        case .appleNativeApps:
            return "统一控制系统日历、备忘录、邮件能力。"
        }
    }

    var boundary: String {
        switch self {
        case .textProcessing:
            return "只处理文本结果，不会触发系统动作。"
        case .feishu:
            return "仅执行 allowlist 内的飞书 CLI 动作。"
        case .appleNativeApps:
            return "只调用本机原生能力，不写入飞书。"
        }
    }

    var mappedFeatures: Set<MagicianFeatureID> {
        switch self {
        case .textProcessing:
            return [.textTransform]
        case .feishu:
            return [.feishuCLI]
        case .appleNativeApps:
            return [.createEvent, .createNote, .composeEmailDraft]
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
    let feishuCLIAvailable: Bool
    let feishuCLICommandName: String?
}
