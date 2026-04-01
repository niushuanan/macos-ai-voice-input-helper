import Foundation

struct V4ToolSpec: Codable, Equatable, Sendable {
    /// 工具稳定名称，供 planner、registry 与日志引用。
    let toolName: String
    /// 工具展示名，主要面向调试 UI 与 history 摘要。
    let displayName: String
    /// 工具职责摘要，供模型与开发者理解用途。
    let summary: String
    /// 允许使用该工具的 lane 列表。
    let supportedLanes: [V4Lane]
    /// 输入 schema 版本，便于后续做兼容迁移。
    let inputSchemaVersion: String
    /// 是否需要显式权限判断。
    let requiresPermission: Bool
    /// 是否会改动用户数据，供 orchestration 做串行或并行判断。
    let mutatesUserData: Bool
    /// 是否支持流式结果，供 Window 05 的 executor 预留能力。
    let supportsStreamingResults: Bool
}

struct V4ToolUse: Codable, Equatable, Sendable {
    /// 当前 tool use 所属 run 标识。
    let runID: V4RunID
    /// 当前 tool use 对应的 step 标识。
    let stepID: V4StepID
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前 tool use 所在 lane。
    let lane: V4Lane
    /// 当前目标摘要，便于 hook 和日志理解上下文。
    let goalSummary: String
    /// 被调用的工具名。
    let toolName: String
    /// 序列化后的输入 JSON 文本，后续便于写盘和回放。
    let inputJSON: String
    /// 面向日志与调试页的输入摘要。
    let inputSummary: String
    /// 发起调用的时间。
    let requestedAt: Date
}

struct V4ToolResult: Codable, Equatable, Sendable {
    /// 当前 tool result 所属 run 标识。
    let runID: V4RunID
    /// 当前 tool result 对应的 step 标识。
    let stepID: V4StepID
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前 tool result 所在 lane。
    let lane: V4Lane
    /// 当前目标摘要。
    let goalSummary: String
    /// 被调用的工具名。
    let toolName: String
    /// 工具输出文本，适合直接回灌 prompt 时使用。
    let outputText: String?
    /// 序列化后的结构化输出 JSON 文本。
    let outputJSON: String?
    /// 工具产出的证据摘要，供 verifier、history、time machine 聚合。
    let evidenceSummary: String
    /// 工具开始执行的时间。
    let startedAt: Date
    /// 工具结束执行的时间。
    let finishedAt: Date
    /// 工具失败信息，成功时为空。
    let error: V4ToolError?
}

struct V4ToolError: Codable, Equatable, Sendable {
    /// 与 V4 主循环统一的失败码。
    let failureCode: V4FailureCode
    /// 面向用户的错误提示。
    let userMessage: String
    /// 面向开发调试的错误补充信息。
    let debugMessage: String?
    /// 是否允许上层尝试重试。
    let isRetryable: Bool
}

struct V4PermissionDecision: Codable, Equatable, Sendable {
    enum Behavior: String, Codable, Equatable, Sendable {
        case allow
        case ask
        case deny
    }

    /// 当前权限判断对应的行为。
    let behavior: Behavior
    /// 当前判断所属 trace 标识。
    let traceID: V4TraceID
    /// 当前判断所在 lane。
    let lane: V4Lane
    /// 当前判断对应的工具名。
    let toolName: String
    /// 规则、hook 或系统能力探测给出的原因。
    let reason: String
    /// 面向用户的提示文案，没有提示时为空。
    let userMessage: String?
}

struct V4ToolHook: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case preflight
        case preExecution = "pre_execution"
        case postExecution = "post_execution"
        case postFailure = "post_failure"
    }

    /// hook 稳定名称，供 registry 与日志追踪。
    let hookName: String
    /// hook 触发阶段。
    let phase: Phase
    /// hook 作用摘要，说明它会改什么或拦什么。
    let summary: String
    /// 是否要求主流程等待该 hook 完成。
    let isBlocking: Bool
}
