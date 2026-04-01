# Window 03 Handoff

## 本窗完成项

- 实现 `V4AgentLoopEngine` 的 turn loop，支持 `while currentTurn < maxTurns`。
- 实现 `V4PlannerRuleBased`，可把文本、苹果原生命令、飞书命令映到可执行 step。
- 实现 `V4PostStepDeciderDefault`，支持 `continue / finish / ask_user / fail` 四种 decision。
- 实现 `V4VerifierDefault`，能产出 verification result 和聚合 evidence summary。
- 实现 `V4MagicianRuntimeAdapter`，可把 `MagicianAgentRequest` 桥到 `V4RunRequest`，再把 outcome / events 映回旧接口。
- 给 `MagicianNativeRuntime` 与 `MagicianAgentRuntimeV3` 加上 `legacy runtime, no new feature` 注释。
- 新增 `Tests/V4AgentLoopEngineTests.swift`，覆盖单步结束、多步继续、retry 成功、retry 耗尽、max turns、事件序列。
- 把 V4 相关源码和新测试显式加入 `PulseType.xcodeproj`，不再只是磁盘占位文件。

## loop 状态机（文字版）

1. `request_accepted`
   V4 接到 `V4RunRequest`，记录 `sessionID / runID / traceID`。
2. `planning`
   调 `V4Planner.plan(...)`。
   若 planner 直接返回 terminal decision，则立即结束本次 run。
3. `plan_ready`
   当前 turn 的 step 列表准备完成。
4. `executing`
   逐 step 执行；每个 step 都有独立 attempt 计数。
5. `retrying`
   step 返回 retryable error 且未超过 `maxRetryPerStep` 时进入。
6. `verifying`
   `V4Verifier.verify(...)` 生成 verification result 与 evidence summary。
7. `decision`
   `V4PostStepDecider.decide(...)` 返回：
   - `continue`：还有后续 segment，要进下一 turn。
   - `finish`：本次 run 成功结束。
   - `ask_user`：需要用户补信息，run 以 `waiting_for_user` 结束。
   - `fail`：run 失败结束。
8. `completed / waiting_for_user / failed`
   发最终事件并返回 `V4RunOutcome`。

补充规则：

- 默认 `maxRetryPerStep = 2`，也就是一个 step 最多执行 3 次。
- 超过 `maxTurns` 仍未完成时，统一返回 `max_turns_exceeded`。

## 事件名列表

- `request_accepted`
- `state_changed`
- `plan_ready`
- `step_started`
- `step_finished`
- `step_retry_scheduled`
- `tool_requested`
- `tool_finished`
- `verification_finished`
- `run_needs_user_input`
- `run_completed`
- `run_failed`

## V4 与 Magician 适配映射

### request

- `MagicianAgentRequest.traceID -> V4RunRequest.traceID`
- `MagicianAgentRequest.command -> V4RunRequest.goalSummary / inputText`
- `MagicianAgentRequest.focusContext.appName -> V4RunRequest.appName`
- `MagicianAgentRequest.focusContext.bundleID -> V4RunRequest.bundleID`
- `MagicianAgentRequest.selectionSnapshot.selectedText -> V4RunRequest.selectionText`
- `MagicianAgentRequest.enabledFeatures -> V4RunRequest.enabledFeatureIDs`
- 当前 adapter 固定把 lane 先桥成 `selectionRewrite`

### event

- `V4RuntimeEvent.status.queued -> MagicianAgentRuntimeState.queued`
- `planning -> planning`
- `executing / waiting_for_tool -> executing_step`
- `retrying -> retrying_step`
- `verifying -> verifying`
- `waiting_for_user -> waiting_for_user`
- `completed -> completed`
- `failed / cancelled -> failed`

- `request_accepted -> request_accepted`
- `plan_ready -> plan_ready`
- `step_started -> step_started`
- `step_finished -> step_finished`
- `step_retry_scheduled -> state_changed`
- `verification_finished(status != failed) -> verification_passed`
- `verification_finished(status == waiting_for_user) -> minimal_question_raised`
- `run_needs_user_input -> minimal_question_raised`
- `run_completed -> run_completed`
- `run_failed -> run_failed`

### outcome

- `V4RunOutcome.sessionID -> MagicianAgentRunOutcome.sessionID`
- `V4RunOutcome.runID -> MagicianAgentRunOutcome.runID`
- `V4RunOutcome.goalSummary -> MagicianAgentRunOutcome.goalSummary`
- `V4RunOutcome.finalStatusMessage -> MagicianAgentRunOutcome.finalStatusMessage`
- `V4RunOutcome.finalOutputText -> MagicianAgentRunOutcome.finalOutputText`
- `V4RunOutcome.displayText -> MagicianAgentRunOutcome.displayText`
- `V4RunOutcome.evidenceSummary -> MagicianAgentRunOutcome.evidenceSummary`
- `V4StepRecord.toolName -> MagicianFeatureID`

## Window 04 需要的 ToolKernel 接口签名

本窗 loop 已经把 step execution 抽成注入式 `StepExecutor`。Window 04 建议直接把下面这些接口落成正式契约：

```swift
protocol V4ToolKernelRunning: Sendable {
    func execute(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords: [V4StepRecord],
        turnIndex: Int
    ) async -> V4ToolResult
}
```

```swift
protocol V4ToolKernelRegistry: Sendable {
    func spec(for toolName: String) -> V4ToolSpec?
    func allSpecs() -> [V4ToolSpec]
}
```

```swift
protocol V4ToolPermissionChecking: Sendable {
    func evaluate(
        toolName: String,
        request: V4RunRequest
    ) async -> V4PermissionDecision
}
```

```swift
protocol V4ToolHookRunning: Sendable {
    func runHooks(
        phase: V4ToolHook.Phase,
        toolUse: V4ToolUse?,
        toolResult: V4ToolResult?
    ) async
}
```

## 本窗命令与结果

- 命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4AgentLoopEngineTests`
  结果：最终通过。`Executed 6 tests, with 0 failures`。

- 命令：`./scripts/test-magician-fast.sh`
  结果：通过。脚本输出 `[test] fast suite passed`。

- 命令：`scripts/auto-ship.sh --message "core: implement v4 agent loop runtime" --files ...`
  结果：通过。生成 `commit 68bb03c`，已 push 到 `origin/codex/magician-agent-v2`，并覆盖安装到 `/Applications/PulseType.app`。

- 中途修正记录：
  - 第一次编译失败点在 `V4MagicianRuntimeAdapter`，原因是 `@MainActor` helper 被同步回调直接调用。
  - 另一次 `xcodebuild` 失败是并发跑两条测试命令时触发 `build.db` 锁，不是代码错误。

## 下一窗第一条动作

1. 把 `StepExecutor` 正式替换成 `V4ToolKernelRunning.execute(...)`，先接 `feishu.cli` 和 `apple.notes.create` 两类真实 adapter。
