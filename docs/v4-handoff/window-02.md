# Window 02 Handoff

## 本窗完成项

- 创建 `Sources/Core/V4/Shared`、`AgentLoop`、`ToolKernel`、`Memory`、`Prompt`、`Model`、`TimeMachine`、`Adapters` 全目录。
- 新建 10 个 V4 基础 contract / bridge 文件，全部可编译。
- 建立 `V4RunID`、`V4SessionID`、`V4StepID`、`V4TraceID` 这组基础标识类型。
- 建立 `V4RunRequest`、`V4RuntimeEvent`、`V4StepRecord`、`V4RunOutcome` 这组主循环运行模型。
- 建立 `V4ToolSpec`、`V4ToolUse`、`V4ToolResult`、`V4ToolError`、`V4PermissionDecision`、`V4ToolHook` 这组工具契约。
- 建立 `V4Planner`、`V4PostStepDecider`、`V4Verifier`、`V4AgentLoopRunning` 这组主循环协议。
- 建立 `V4ModelSlot`、`V4ModelEndpoint`、`V4ModelCredentialRef` 这组模型槽位契约。
- 建立 `V4PromptContext`、`V4PromptLayer`、`V4PromptEnvelope` 这组 prompt 契约。
- 建立 `V4MemoryEntry`、`V4MemoryQuery`、`V4MemoryHit` 这组 memory 契约。
- 建立 `V4TimeItem`、`V4ReminderSpec`、`V4TimeIntent` 这组 time machine 契约。
- 新建 `docs/v4/architecture/v4-type-mapping.md`，给旧类型到新类型做第一版映射。
- 新建 `V4ToSessionStoreBridge` 与 `V4ToHistoryBridge` 占位，并在 TODO 里标明 Window 05/06 需要接入的字段。

## 新增目录列表

- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/Shared`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/AgentLoop`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/Memory`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/Prompt`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/Model`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/TimeMachine`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/Adapters`

## 新增类型列表

- `V4RunID`
- `V4SessionID`
- `V4StepID`
- `V4TraceID`
- `V4Lane`
- `V4RunStatus`
- `V4FailureCode`
- `V4RuntimeEventName`
- `V4RunRequest`
- `V4RuntimeEvent`
- `V4StepRecord`
- `V4RunOutcome`
- `V4ToolSpec`
- `V4ToolUse`
- `V4ToolResult`
- `V4ToolError`
- `V4PermissionDecision`
- `V4ToolHook`
- `V4Planner`
- `V4PostStepDecider`
- `V4Verifier`
- `V4AgentLoopRunning`
- `V4ModelSlot`
- `V4ModelEndpoint`
- `V4ModelCredentialRef`
- `V4PromptContext`
- `V4PromptLayer`
- `V4PromptEnvelope`
- `V4MemoryEntry`
- `V4MemoryQuery`
- `V4MemoryHit`
- `V4TimeItem`
- `V4ReminderSpec`
- `V4TimeIntent`
- `V4ToSessionStoreBridge`
- `V4ToHistoryBridge`

## 类型映射摘要

- `MagicianAgentRequest -> V4RunRequest`：重写，保留 `traceID`、lane、上下文快照，去掉旧 runtime 耦合。
- `MagicianAgentRuntimeEvent -> V4RuntimeEvent`：重写，改成统一可序列化事件。
- `MagicianAgentRunOutcome -> V4RunOutcome`：重写，保留目标、steps、evidence 三块结果面。
- `MagicianExecutionResult -> V4ToolResult / V4ToolError`：重写，把执行结果拆成工具结果与失败模型。
- `SessionHistoryEntry -> V4MemoryEntry / V4TimeItem / V4ToHistoryBridge`：旧历史先继续用，后续经 bridge 渐进迁移。

完整表见：

- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/v4-type-mapping.md`

## Window 03 需要实现的方法签名

```swift
func run(
    request: V4RunRequest,
    onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
) async throws -> V4RunOutcome
```

```swift
func plan(for request: V4RunRequest) async throws -> [V4StepRecord]
```

```swift
func shouldContinue(
    after latestStep: V4StepRecord,
    accumulatedStepRecords: [V4StepRecord],
    latestToolResult: V4ToolResult?,
    for request: V4RunRequest
) async -> Bool
```

```swift
func buildEvidenceSummary(
    for request: V4RunRequest,
    stepRecords: [V4StepRecord],
    latestToolResult: V4ToolResult?
) async -> String
```

```swift
func applyRunStart(
    request: V4RunRequest,
    to sessionStore: SessionStore
)
```

```swift
func applyRuntimeEvent(
    _ event: V4RuntimeEvent,
    to sessionStore: SessionStore
)
```

```swift
func applyRunOutcome(
    _ outcome: V4RunOutcome,
    to sessionStore: SessionStore
)
```

## 本窗命令与结果

- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" build`
  结果：失败。原因不是代码，而是当前 `xcode-select` 指向 `/Library/Developer/CommandLineTools`。
- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" build`
  结果：通过。`BUILD SUCCEEDED`。
- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && ./scripts/test-magician-fast.sh`
  结果：通过。脚本输出 `[test] fast suite passed`。
- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && scripts/auto-ship.sh --message "core: add v4 window 02 contracts skeleton" --files ... --with-test`
  结果：失败。`xcodebuild test` 返回 `PulseType (...) encountered an error (The test runner hung before establishing connection.)`，属于本机 test host 连接异常，不是本窗新增类型的编译错误。

## 下一窗提醒

1. Window 03 要开始把 post-ASR 主流程搬进 `V4AgentLoop`，但先只接 coordinator 入口桥，不删旧 runtime。
2. `V4ToSessionStoreBridge` 目前只是占位，真正更新 `phase/statusMessage/hudProgressHint` 的逻辑要在 Window 03 起步，Window 05/06 补齐 tool 与 writeback 字段。
3. `V4ToHistoryBridge` 目前故意不落盘，避免在 contracts 还没被主流程使用前引入双写分叉。
