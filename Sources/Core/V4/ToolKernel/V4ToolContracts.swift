import Foundation

typealias V4ToolArguments = [String: V4ToolValue]

enum V4ToolResultStatus: String, Codable, Equatable, Sendable {
    case success
    case failed
    case denied
}

enum V4ToolValueKind: String, Codable, Equatable, Sendable {
    case string
    case number
    case boolean
    case array
    case object
    case null

    var displayName: String {
        switch self {
        case .string:
            return "字符串"
        case .number:
            return "数字"
        case .boolean:
            return "布尔值"
        case .array:
            return "数组"
        case .object:
            return "对象"
        case .null:
            return "空值"
        }
    }
}

enum V4ToolValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([V4ToolValue])
    case object([String: V4ToolValue])
    case null

    var kind: V4ToolValueKind {
        switch self {
        case .string:
            return .string
        case .number:
            return .number
        case .boolean:
            return .boolean
        case .array:
            return .array
        case .object:
            return .object
        case .null:
            return .null
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .boolean(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [V4ToolValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var objectValue: [String: V4ToolValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let boolValue = try? container.decode(Bool.self) {
                self = .boolean(boolValue)
                return
            }
            if let intValue = try? container.decode(Int.self) {
                self = .number(Double(intValue))
                return
            }
            if let doubleValue = try? container.decode(Double.self) {
                self = .number(doubleValue)
                return
            }
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
                return
            }
        }

        if var arrayContainer = try? decoder.unkeyedContainer() {
            var values = [V4ToolValue]()
            while !arrayContainer.isAtEnd {
                values.append(try arrayContainer.decode(V4ToolValue.self))
            }
            self = .array(values)
            return
        }

        if let keyedContainer = try? decoder.container(keyedBy: V4ToolDynamicCodingKey.self) {
            var object = [String: V4ToolValue]()
            for key in keyedContainer.allKeys {
                object[key.stringValue] = try keyedContainer.decode(V4ToolValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON payload."
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            if value.rounded(.towardZero) == value {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case let .boolean(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: V4ToolDynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: V4ToolDynamicCodingKey(stringValue: key)!)
            }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

struct V4ToolDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct V4ToolInputField: Codable, Equatable, Sendable {
    let name: String
    let kind: V4ToolValueKind
    let isRequired: Bool
    let itemKind: V4ToolValueKind?
    let summary: String

    init(
        name: String,
        kind: V4ToolValueKind,
        isRequired: Bool = true,
        itemKind: V4ToolValueKind? = nil,
        summary: String
    ) {
        self.name = name
        self.kind = kind
        self.isRequired = isRequired
        self.itemKind = itemKind
        self.summary = summary
    }

    func validate(value: V4ToolValue?) -> String? {
        guard let value else {
            return isRequired ? "缺少字段 `\(name)`。" : nil
        }

        guard value.kind == kind else {
            return "字段 `\(name)` 应为\(kind.displayName)，当前是\(value.kind.displayName)。"
        }

        if
            kind == .array,
            let itemKind,
            let arrayValue = value.arrayValue,
            arrayValue.contains(where: { $0.kind != itemKind })
        {
            return "字段 `\(name)` 的数组元素应全部为\(itemKind.displayName)。"
        }

        return nil
    }
}

struct V4ToolInputSchema: Codable, Equatable, Sendable {
    let fields: [V4ToolInputField]
    let allowsAdditionalFields: Bool

    init(
        fields: [V4ToolInputField],
        allowsAdditionalFields: Bool = false
    ) {
        self.fields = fields
        self.allowsAdditionalFields = allowsAdditionalFields
    }

    func validate(arguments: V4ToolArguments) -> [String] {
        var issues = fields.compactMap { $0.validate(value: arguments[$0.name]) }
        if !allowsAdditionalFields {
            let allowedNames = Set(fields.map(\.name))
            let extras = arguments.keys.filter { !allowedNames.contains($0) }.sorted()
            if !extras.isEmpty {
                issues.append("存在未定义字段：\(extras.joined(separator: ", "))。")
            }
        }
        return issues
    }
}

struct V4ToolSpec: Codable, Equatable, Sendable {
    let toolName: String
    let displayName: String
    let summary: String
    let supportedLanes: [V4Lane]
    let inputSchemaVersion: String
    let inputSchema: V4ToolInputSchema
    let requiresPermission: Bool
    let permissionScope: MagicianPermissionScope?
    let isConcurrencySafe: Bool
    let mutatesUserData: Bool
    let supportsStreamingResults: Bool

    var toolID: String { toolName }
}

struct V4ToolUse: Codable, Equatable, Sendable {
    let runID: V4RunID
    let stepID: V4StepID
    let traceID: V4TraceID
    let lane: V4Lane
    let goalSummary: String
    let toolName: String
    let inputJSON: String
    let inputSummary: String
    let requestedAt: Date

    var toolID: String { toolName }
}

struct V4ToolResult: Codable, Equatable, Sendable {
    let runID: V4RunID
    let stepID: V4StepID
    let traceID: V4TraceID
    let lane: V4Lane
    let goalSummary: String
    let toolName: String
    let status: V4ToolResultStatus
    let outputText: String?
    let evidenceSummary: String
    let rawPayload: String?
    let startedAt: Date
    let finishedAt: Date
    let error: V4ToolError?

    var toolID: String { toolName }
}

struct V4ToolError: Error, Codable, Equatable, Sendable {
    let code: V4FailureCode
    let toolID: String
    let messageForUser: String
    let messageForDebug: String
    let recoverAction: String?
    let isRetryable: Bool

    var failureCode: V4FailureCode { code }
    var userMessage: String { messageForUser }
    var debugMessage: String? {
        messageForDebug.isEmpty ? nil : messageForDebug
    }
}

struct V4PermissionDecision: Codable, Equatable, Sendable {
    enum Behavior: String, Codable, Equatable, Sendable {
        case allow
        case ask
        case deny
    }

    let behavior: Behavior
    let traceID: V4TraceID
    let lane: V4Lane
    let toolName: String
    let reason: String
    let userMessage: String?
}

struct V4ToolHook: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case preflight
        case preExecution = "pre_execution"
        case postExecution = "post_execution"
        case postFailure = "post_failure"
    }

    let hookName: String
    let phase: Phase
    let summary: String
    let isBlocking: Bool
}

struct V4ToolExecutionContext: Sendable {
    let toolUse: V4ToolUse
    let request: V4RunRequest
    let step: V4StepRecord
    let accumulatedStepRecords: [V4StepRecord]
    let turnIndex: Int

    var latestCompletedOutputText: String? {
        accumulatedStepRecords.reversed().compactMap(\.outputSummary).first
    }
}

struct V4ToolSemanticValidationFailure: Equatable, Sendable {
    let code: V4FailureCode
    let messageForUser: String
    let messageForDebug: String
    let recoverAction: String?

    init(
        code: V4FailureCode = .toolValidationFailed,
        messageForUser: String,
        messageForDebug: String,
        recoverAction: String? = "retry_command"
    ) {
        self.code = code
        self.messageForUser = messageForUser
        self.messageForDebug = messageForDebug
        self.recoverAction = recoverAction
    }
}

struct V4ToolExecutionOutput: Equatable, Sendable {
    let outputText: String?
    let evidenceSummary: String
    let rawPayload: V4ToolValue?

    init(
        outputText: String?,
        evidenceSummary: String,
        rawPayload: V4ToolValue? = nil
    ) {
        self.outputText = outputText
        self.evidenceSummary = evidenceSummary
        self.rawPayload = rawPayload
    }
}

struct V4ToolPreHookResult: Equatable, Sendable {
    let input: V4ToolArguments
    let evidenceLines: [String]

    init(input: V4ToolArguments, evidenceLines: [String] = []) {
        self.input = input
        self.evidenceLines = evidenceLines
    }
}

struct V4ToolPostHookResult: Equatable, Sendable {
    let output: V4ToolExecutionOutput
    let evidenceLines: [String]

    init(output: V4ToolExecutionOutput, evidenceLines: [String] = []) {
        self.output = output
        self.evidenceLines = evidenceLines
    }
}

protocol V4Tool: Sendable {
    var spec: V4ToolSpec { get }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure?

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput
}

extension V4Tool {
    func validateSemanticInput(
        arguments _: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        nil
    }
}

protocol V4ToolKernelRegistry: Sendable {
    func spec(for toolName: String) -> V4ToolSpec?
    func allSpecs() -> [V4ToolSpec]
}

protocol V4ToolPermissionChecking: Sendable {
    func evaluate(
        spec: V4ToolSpec,
        request: V4RunRequest
    ) async -> V4PermissionDecision
}

protocol V4ToolLifecycleHook: Sendable {
    var descriptor: V4ToolHook { get }

    func beforeExecution(
        toolUse: V4ToolUse,
        input: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPreHookResult?

    func afterExecution(
        toolUse: V4ToolUse,
        output: V4ToolExecutionOutput,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPostHookResult?

    func afterFailure(
        toolUse: V4ToolUse,
        error: V4ToolError,
        context: V4ToolExecutionContext
    ) async
}

extension V4ToolLifecycleHook {
    func beforeExecution(
        toolUse _: V4ToolUse,
        input _: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolPreHookResult? {
        nil
    }

    func afterExecution(
        toolUse _: V4ToolUse,
        output _: V4ToolExecutionOutput,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolPostHookResult? {
        nil
    }

    func afterFailure(
        toolUse _: V4ToolUse,
        error _: V4ToolError,
        context _: V4ToolExecutionContext
    ) async {}
}

protocol V4ToolHookRunning: Sendable {
    func runPreHooks(
        toolUse: V4ToolUse,
        input: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPreHookResult

    func runPostHooks(
        toolUse: V4ToolUse,
        output: V4ToolExecutionOutput,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPostHookResult

    func runFailureHooks(
        toolUse: V4ToolUse,
        error: V4ToolError,
        context: V4ToolExecutionContext
    ) async

    func allHooks() -> [V4ToolHook]
}

protocol V4ToolKernelRunning: Sendable {
    func execute(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords: [V4StepRecord],
        turnIndex: Int
    ) async -> V4ToolResult
}

protocol V4ToolBatchOrchestrating: Sendable {
    func execute(
        toolUses: [V4ToolUse],
        contexts: [V4ToolExecutionContext]
    ) async -> [V4ToolResult]
}

extension Dictionary where Key == String, Value == V4ToolValue {
    func string(for key: String) -> String? {
        self[key]?.stringValue
    }

    func number(for key: String) -> Double? {
        self[key]?.numberValue
    }

    func bool(for key: String) -> Bool? {
        self[key]?.boolValue
    }

    func stringArray(for key: String) -> [String]? {
        guard let values = self[key]?.arrayValue else {
            return nil
        }
        return values.compactMap(\.stringValue)
    }
}
