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

enum MagicianMusicCapability {
    static var musicAppAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil
            || FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
    }
}

enum MagicianClockSurface: String, CaseIterable {
    case worldClock
    case alarm
    case timer

    var displayName: String {
        switch self {
        case .worldClock:
            return "时钟"
        case .alarm:
            return "闹钟"
        case .timer:
            return "计时器"
        }
    }

    var urlString: String {
        switch self {
        case .worldClock:
            return "clock-worldclock://"
        case .alarm:
            return "clock-alarm://"
        case .timer:
            return "clock-timer://"
        }
    }
}

enum MagicianClockCapability {
    static let bundleIdentifier = "com.apple.clock"
    static let appPath = "/System/Applications/Clock.app"

    static var clockAppAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
            || FileManager.default.fileExists(atPath: appPath)
    }

    static func canOpen(surface: MagicianClockSurface) -> Bool {
        guard let url = URL(string: surface.urlString) else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil || clockAppAvailable
    }

    static var handoffAvailable: Bool {
        clockAppAvailable
    }
}

struct MagicianCreateNoteShortcutSupport: @unchecked Sendable {
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

enum MagicianFeatureID: String, CaseIterable, Identifiable {
    case textTransform = "text_transform"
    case calendar = "calendar"
    case markdownDocument = "markdown_document"
    case mail = "mail"
    case music = "music"
    case clock = "clock"
    case createEvent = "create_event"
    case createNote = "create_note"
    case composeEmailDraft = "compose_email_draft"
    case controlMusic = "control_music"
    case feishuCLI = "feishu_cli"

    var id: String { rawValue }

    static var allCases: [MagicianFeatureID] {
        [
            .textTransform,
            .calendar,
            .markdownDocument,
            .mail,
            .music,
            .clock
        ]
    }

    var canonicalFeature: MagicianFeatureID {
        switch self {
        case .createEvent:
            return .calendar
        case .createNote:
            return .markdownDocument
        case .composeEmailDraft:
            return .mail
        case .controlMusic:
            return .music
        default:
            return self
        }
    }

    var displayName: String {
        switch canonicalFeature {
        case .textTransform:
            return "文本处理"
        case .calendar:
            return "日历"
        case .markdownDocument:
            return "Markdown 文档"
        case .mail:
            return "邮件"
        case .music:
            return "音乐"
        case .clock:
            return "时钟"
        case .feishuCLI:
            return "飞书 CLI"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.displayName
        }
    }

    var progressTitle: String {
        switch canonicalFeature {
        case .textTransform:
            return "文本处理中"
        case .calendar:
            return "创建日程中"
        case .markdownDocument:
            return "生成 Markdown 文档中"
        case .mail:
            return "整理邮件中"
        case .music:
            return "控制音乐中"
        case .clock:
            return "处理时钟动作中"
        case .feishuCLI:
            return "执行飞书命令中"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.progressTitle
        }
    }

    var summaryLine: String {
        switch canonicalFeature {
        case .textTransform:
            return "长按魔术先生，直接处理当前文字。"
        case .calendar:
            return "把一句话里的时间和主题写进系统日历。"
        case .markdownDocument:
            return "把内容整理成 Markdown 文档并落到本地。"
        case .mail:
            return "整理主题和正文，打开 Mail 或直接发出。"
        case .music:
            return "一句话控制 Music：播放、暂停、继续、切歌。"
        case .clock:
            return "负责提醒、计时和打开系统 Clock。"
        case .feishuCLI:
            return "保留给内部兼容链路，不再属于主体验。"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.summaryLine
        }
    }

    var boundaryLine: String {
        switch canonicalFeature {
        case .textTransform:
            return "只处理文字，不直接触发系统动作。"
        case .calendar:
            return "只写入本机日历，不帮你群发或同步外部服务。"
        case .markdownDocument:
            return "主路径统一走 md.pipeline，不再混 Notes 文案。"
        case .mail:
            return "地址不够稳时只打开编辑窗口，不会直接发。"
        case .music:
            return "只控制本机 Music，不改动你的资料库。"
        case .clock:
            return "保证路径仍是本地提醒；打开 Clock 属于尽力而为。"
        case .feishuCLI:
            return "仅保留给内部兼容逻辑，不再在主界面出现。"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.boundaryLine
        }
    }

    var sampleCommand: String {
        switch canonicalFeature {
        case .textTransform:
            return "把这段话改得更利落"
        case .calendar:
            return "周五下午和产品开评审会"
        case .markdownDocument:
            return "整理后保存成 Markdown 文档"
        case .mail:
            return "给小庄发邮件"
        case .music:
            return "播放稻香"
        case .clock:
            return "30 分钟后提醒我开会"
        case .feishuCLI:
            return "飞书查今天议程"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.sampleCommand
        }
    }

    var symbolName: String {
        switch canonicalFeature {
        case .textTransform:
            return "text.bubble"
        case .calendar:
            return "calendar"
        case .markdownDocument:
            return "doc.text"
        case .mail:
            return "envelope"
        case .music:
            return "music.note"
        case .clock:
            return "alarm"
        case .feishuCLI:
            return "paperplane.circle"
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return canonicalFeature.symbolName
        }
    }

    var isNativeAction: Bool {
        canonicalFeature != .textTransform && canonicalFeature != .feishuCLI
    }

    static func fromStoredRawValue(_ rawValue: String) -> Self? {
        switch rawValue {
        case Self.textTransform.rawValue:
            return .textTransform
        case Self.calendar.rawValue, Self.createEvent.rawValue:
            return .calendar
        case Self.markdownDocument.rawValue, Self.createNote.rawValue:
            return .markdownDocument
        case Self.mail.rawValue, Self.composeEmailDraft.rawValue:
            return .mail
        case Self.music.rawValue, Self.controlMusic.rawValue:
            return .music
        case Self.clock.rawValue:
            return .clock
        case Self.feishuCLI.rawValue:
            return .feishuCLI
        default:
            return nil
        }
    }
}

extension MagicianFeatureID: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self.fromStoredRawValue(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown magician feature id: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
    case enabled
}

enum MagicianFeatureAvailability: String, Equatable {
    case ready
    case blocked
}

enum MagicianFeatureGateKind: String, Equatable {
    case ready
    case systemPermission
    case serviceDependency
    case modelDependency
}

struct MagicianDependencySnapshot: Equatable {
    let accessibilityState: PermissionState
    let textModelReady: Bool
    let eventAuthorizationStatus: EKAuthorizationStatus
    let composeEmailAvailable: Bool
    let mailtoAvailable: Bool
    let mailAppAvailable: Bool
    let musicAppAvailable: Bool
    let notificationAuthorizationStatus: V4NotificationAuthorizationStatus
    let clockAppAvailable: Bool
    let clockAlarmSurfaceAvailable: Bool
    let clockTimerSurfaceAvailable: Bool

    var clockHandoffAvailable: Bool {
        clockAppAvailable || clockAlarmSurfaceAvailable || clockTimerSurfaceAvailable
    }
}
