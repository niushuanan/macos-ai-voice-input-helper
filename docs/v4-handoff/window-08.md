# Window 08 - 时光机模块接入

## 本窗目标

- 新增时光机核心模块，并接入 V4 ToolKernel 主循环
- 支持“仅记录灵感”和“记录并设提醒”两类输入
- 提醒走本地通知，不依赖云端
- 产出可给 V4 memory / prompt 复用的用户画像摘要

## 本窗落地文件

- `Sources/Core/V4/TimeMachine/V4TimeMachineContracts.swift`
- `Sources/Core/V4/TimeMachine/V4TimeMachineService.swift`
- `Sources/Core/V4/TimeMachine/V4TimeParser.swift`
- `Sources/Core/V4/TimeMachine/V4ReminderScheduler.swift`
- `Sources/Core/V4/TimeMachine/V4TimeMachineStore.swift`
- `Sources/Core/V4/TimeMachine/V4UserProfileDigest.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TimeMachineCreateTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TimeMachineRemindTool.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift`
- `Sources/Core/V4/ToolKernel/V4ToolKernel.swift`
- `Sources/Core/V4/AgentLoop/V4PlannerRuleBased.swift`
- `Sources/Core/V4/Prompt/V4PromptContracts.swift`
- `Sources/Core/V4/Prompt/V4PromptLayerProviders.swift`
- `Sources/Core/V4/Prompt/V4PromptStackResolver.swift`
- `Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift`
- `Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift`
- `Sources/Core/Interaction/InteractionCoordinator.swift`
- `Sources/App/AppModel.swift`
- `PulseType.xcodeproj/project.pbxproj`
- `Tests/V4TimeParserTests.swift`
- `Tests/V4ReminderSchedulerTests.swift`
- `Tests/V4TimeMachineServiceTests.swift`
- `docs/v4/architecture/v4-master-architecture.md`
- `docs/v4-handoff/window-08.md`

## 时光机字段模型

本窗实际落盘模型是 `V4TimeItem`，字段如下：

- `id`
- `createdAt`
- `rawCommand`
- `normalizedText`
- `scheduledAt`
- `notificationID`
- `tags`
- `status`

附加追踪字段：

- `sessionID`
- `runID`
- `traceID`
- `lane`

落盘路径：

- `history/time-machine-items-v1.json`

## 时间解析覆盖范围

当前已覆盖的中文表达：

- `今晚 8 点`
- `明早 9 点`
- `下周一上午`
- `30 分钟后`

解析结果统一返回 `V4TimeParseResult`：

- 成功时给出 `kind / matchedExpression / scheduledAt / resolutionSummary`
- 失败时给出 `hint.code / hint.userMessage / hint.debugMessage / supportedExamples`

当前未覆盖：

- 多时间点拆分，例如“明早 9 点和下午 3 点都提醒我”
- 节假日、农历、法定工作日推导
- 复杂区间或条件组合，例如“下周工作日晚上 8 点后”
- 重复提醒规则

## 提醒调度边界

- 只使用本地通知
- 只在 parser 产出明确 `scheduledAt` 时调度
- 调度成功会记录 `notificationID`
- 调度失败不会丢条目，状态记成 `schedule_failed`
- 权限被拒绝时会给结构化失败信息，不会静默吞掉

## V4 主循环接线

planner 新增 action：

- `time_machine.create`
- `time_machine.remind`

ToolKernel 新增 tool：

- `time_machine.create`
- `time_machine.remind`

step 证据摘要现在会写入：

- 创建条目 ID
- 时间解析结果
- 调度结果

另外，prompt / memory 层新增 `TimeMachine` layer，用于注入轻量画像摘要，不允许覆盖当前命令的明确目标。

## 用户画像沉淀

`V4UserProfileDigest` 当前提炼三类信息：

- 高频主题
- 常见提醒时间段
- 常见 action 标签

当前用途：

- 注入 `V4PromptLayerProviders.timeMachine(...)`
- 注入 `V4MemoryQueryPlannerInputAdapter` 的 `memoryHint`

## Window 09 要迁移的 tool 列表

下一窗建议继续往统一内核迁移这些 tool：

- `apple.calendar.create`
- `apple.notes.create`
- `apple.mail.compose`
- `apple.music.control`
- `feishu.cli`

原因：

- 时光机已经把“本地持久化 + 调度结果 + 画像摘要”这条链打通了
- 下一步更适合把外部动作 tool 的结构化结果也统一进 memory / trace / personalization

## 本窗命令与结果

### 定向测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4TimeParserTests -only-testing:PulseTypeTests/V4ReminderSchedulerTests -only-testing:PulseTypeTests/V4TimeMachineServiceTests
```

结果：

- 8 tests, 0 failures
- `V4TimeParserTests` 全部通过
- `V4ReminderSchedulerTests` 全部通过
- `V4TimeMachineServiceTests` 全部通过

### fast suite

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
./scripts/test-magician-fast.sh
```

结果：

- `fast suite passed`

### 自动发布

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
scripts/auto-ship.sh --message "core: add v4 time machine tools" --files PulseType.xcodeproj/project.pbxproj Sources/App/AppModel.swift Sources/Core/Interaction/InteractionCoordinator.swift Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift Sources/Core/V4/AgentLoop/V4PlannerRuleBased.swift Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift Sources/Core/V4/Prompt/V4PromptContracts.swift Sources/Core/V4/Prompt/V4PromptLayerProviders.swift Sources/Core/V4/Prompt/V4PromptStackResolver.swift Sources/Core/V4/TimeMachine/V4ReminderScheduler.swift Sources/Core/V4/TimeMachine/V4TimeMachineContracts.swift Sources/Core/V4/TimeMachine/V4TimeMachineService.swift Sources/Core/V4/TimeMachine/V4TimeMachineStore.swift Sources/Core/V4/TimeMachine/V4TimeParser.swift Sources/Core/V4/TimeMachine/V4UserProfileDigest.swift Sources/Core/V4/ToolKernel/Tools/V4TimeMachineCreateTool.swift Sources/Core/V4/ToolKernel/Tools/V4TimeMachineRemindTool.swift Sources/Core/V4/ToolKernel/V4ToolKernel.swift Sources/Core/V4/ToolKernel/V4ToolRegistry.swift Tests/V4ReminderSchedulerTests.swift Tests/V4TimeMachineServiceTests.swift Tests/V4TimeParserTests.swift docs/v4/architecture/v4-master-architecture.md docs/v4-handoff/window-08.md
```

结果：

- 待执行
