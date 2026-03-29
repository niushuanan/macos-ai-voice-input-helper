import Foundation

enum FeishuOperationSupportTier: String, CaseIterable, Equatable {
    case direct = "direct"
    case resolveTargetFirst = "resolve_target_first"
    case explicitResourceRequired = "explicit_resource_required"
    case mappingNeedsRepair = "mapping_needs_repair"

    var title: String {
        switch self {
        case .direct:
            return "可直接办"
        case .resolveTargetFirst:
            return "会先找对象再办"
        case .explicitResourceRequired:
            return "仍需你给关键对象"
        case .mappingNeedsRepair:
            return "需谨慎使用"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            return "一句自然话通常就能直接完成。"
        case .resolveTargetFirst:
            return "会先帮你找人、群、文档或资源，再继续执行。"
        case .explicitResourceRequired:
            return "如果没有明确 URL、token、ID 或本地文件，系统不会盲猜。"
        case .mappingNeedsRepair:
            return "这类能力已接入，但还要先做更严格的目标解析和参数规划。"
        }
    }
}

struct FeishuOperationDescriptor: Equatable {
    let operation: FeishuCanonicalOperation
    let supportTier: FeishuOperationSupportTier
    let summary: String
    let requiresStructuredVerification: Bool
}

enum FeishuOperationCatalog {
    private static let descriptors: [FeishuCanonicalOperation: FeishuOperationDescriptor] = {
        Dictionary(
            uniqueKeysWithValues: FeishuCanonicalOperation.allCases.map { operation in
                (operation, descriptor(for: operation))
            }
        )
    }()

    static func descriptor(for operation: FeishuCanonicalOperation) -> FeishuOperationDescriptor {
        switch operation {
        case .calendarCalendar:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "查看今天或指定时间段的飞书日程。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .calendarEvent:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "按自然语言创建飞书日程，并核验 event_id。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .calendarFreebusy:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "查看时间段忙闲状态。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .chat, .imUserSearchMessages, .searchDocWiki, .searchUser, .oauth, .oauthBatchAuth:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "高频查询或授权动作，通常可直接完成。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .bitableApp:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "支持创建基础多维表格，建成后会核验 base 标识。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .imUserMessage:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "唯一目标可直接发消息，系统会先尝试自动找目标。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .chatMembers, .fetchDoc, .updateDoc, .docComments, .driveFile, .sheet, .taskTask, .taskTasklist, .taskSubtask, .wikiSpace, .wikiSpaceNode:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .resolveTargetFirst,
                summary: "先找对象，再执行动作。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .docMedia, .imUserFetchResource, .imBotImage, .bitableAppTableField, .bitableAppTableRecord, .bitableAppTableView, .bitableAppTable, .calendarEventAttendee, .imUserGetMessages, .imUserGetThreadMessages, .taskComment:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .explicitResourceRequired,
                summary: "必须先有明确资源或对象，缺关键对象时不会盲猜。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .createDoc:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .resolveTargetFirst,
                summary: "可创建文档并核验文档标识。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        case .getUser:
            return FeishuOperationDescriptor(
                operation: operation,
                supportTier: .direct,
                summary: "获取当前用户信息。",
                requiresStructuredVerification: operation.riskLevel != .read
            )
        }
    }

    static func allDescriptors() -> [FeishuOperationDescriptor] {
        FeishuCanonicalOperation.allCases.compactMap { descriptors[$0] }
    }

    static func groupedBySupportTier() -> [(tier: FeishuOperationSupportTier, operations: [FeishuOperationDescriptor])] {
        FeishuOperationSupportTier.allCases.compactMap { tier in
            let operations = allDescriptors()
                .filter { $0.supportTier == tier }
                .sorted { $0.operation.rawValue < $1.operation.rawValue }
            guard !operations.isEmpty else {
                return nil
            }
            return (tier: tier, operations: operations)
        }
    }

    static func groupedByDomain() -> [(group: String, operations: [FeishuCanonicalOperation])] {
        let groups = Dictionary(grouping: FeishuCanonicalOperation.allCases, by: \.groupTitle)
        return groups
            .map { key, value in
                (group: key, operations: value.sorted(by: { $0.rawValue < $1.rawValue }))
            }
            .sorted(by: { $0.group < $1.group })
    }
}
