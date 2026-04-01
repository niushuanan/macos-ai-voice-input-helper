# Window 07 - V4 PromptStack 与 ModelSlots

## 本窗目标

- 建立 `V4PromptStackResolver`
- 建立 `V4ModelSlotManager`
- 让 V4 主循环统一先解析 prompt / model，再进入 planner 与 tool
- 保持设置页原有操作不变

## 本窗落地文件

- `Sources/Core/V4/Prompt/V4PromptContracts.swift`
- `Sources/Core/V4/Prompt/V4PromptLayerProviders.swift`
- `Sources/Core/V4/Prompt/V4PromptStackResolver.swift`
- `Sources/Core/V4/Model/V4ModelSlotContracts.swift`
- `Sources/Core/V4/Model/V4ModelSlots.swift`
- `Sources/Core/V4/Model/V4ModelSlotManager.swift`
- `Sources/Core/V4/Adapters/V4ProviderSettingsBridge.swift`
- `Sources/Core/V4/Adapters/V4SkillRuleBridge.swift`
- `Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TextTransformTool.swift`
- `Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift`
- `Sources/Core/V4/Adapters/V4ToHistoryBridge.swift`
- `Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift`
- `Sources/Core/Interaction/InteractionCoordinator.swift`
- `Sources/App/AppModel.swift`
- `Tests/V4PromptStackResolverTests.swift`
- `Tests/V4ModelSlotManagerTests.swift`
- `docs/v4/architecture/v4-master-architecture.md`
- `docs/v4-handoff/window-07.md`

## PromptStack 固定规则

固定顺序：

1. `Global`
2. `NowYouSeeMe`
3. `AppScene`
4. `Lane`
5. `Task`

合并规则：

- `systemPrompt`：按层级顺序拼接，并带 `[LayerName]` 标记
- `guidance`：按 key 合并；同 key 后层覆盖前层
- `constraints`：按 key 合并；同 key 后层覆盖前层
- `userPrompt`：后层覆盖前层

输出结构：

- `finalSystemPrompt`
- `finalGuidancePrompt`
- `finalUserPrompt`
- `appliedLayers`

## PromptStack 示例

### 示例 1：魔术先生

输入条件：

- lane：`selectionRewrite`
- spoken command：`把这段纪要改成更直接的版本`
- selection：`今天讨论了发布和预算...`
- `spokenFilter=嗯,啊`
- `systemPrompt=请更直接。`
- AppScene：`TextEdit -> 优先输出可直接粘贴的结果。`

解析结果概念上会变成：

- `Global`
  - system：V4 统一执行规则
- `NowYouSeeMe`
  - system：`请更直接。`
  - guidance：输入清洗策略
- `AppScene`
  - guidance：`当前应用 TextEdit，优先输出可直接粘贴的结果`
- `Lane`
  - guidance / constraints：魔术先生的外部动作边界
- `Task`
  - user：任务目标 + 待处理文本

### 示例 2：一口气全念对

输入条件：

- lane：`brainstormDiscussion`
- transcript：`我们先把支付接好，再做官网，最好下周前出可演示版`
- AppScene 关闭
- `spokenFilter` 关闭

解析结果概念上会变成：

- `Global`
  - system：V4 统一执行规则
- `Lane`
  - guidance / constraints：把讨论整理成可直接给 AI 的上下文包
- `Task`
  - user：讨论目标 + 讨论原文

也就是说，这条链不会凭空带入 `NowYouSeeMe` 或 `AppScene` 段。

## Now you see me 映射

`V4SkillRuleBridge` 只负责这三项：

1. `spokenFilter`
   - 注入输入清洗说明
2. `appPreferenceBoost`
   - 控制 `AppScene` 是否允许注入
3. `systemPrompt`
   - 直接进 `NowYouSeeMe.systemPrompt`

边界规则：

- 开关关闭，不注入
- 参数空白，不注入
- 不制造空段落

## 三槽位解析流程

`V4ModelSlotManager -> V4ModelSlots`

1. `asr`
   - 来源：`ProviderSettingsStore.asrConfig`
2. `text`
   - 来源：`ProviderSettingsStore.textConfig`
3. `agent`
   - 当前默认来源：`ProviderSettingsStore.cliTextConfig`
   - 未来若要独立 provider，只改 `V4ProviderSettingsBridge`

当前解析链：

1. `V4ProviderSettingsBridge` 把旧 store 变成 `V4ProviderSlotSnapshot`
2. `V4ModelSlotManager` 校验 provider 能力、model name、base URL
3. 校验通过后产出 `V4ModelEndpoint`
4. `V4AgentLoopEngine` 每轮把 `modelSlots` 写回 `V4RunRequest`
5. `V4TextTransformTool` 只读 `request.modelSlots`

## 本窗删除的旧 prompt 拼接点

本窗真正拿掉的 V4 旧入口有这些：

- `Sources/Core/V4/ToolKernel/Tools/V4TextTransformTool.swift`
  - 删除直接读 `ProviderSettingsStore.rewriteConfiguration`
  - 删除直接读 `loadAPIKeyForRewriteProvider()`
- `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift`
  - 删除把 `ProviderSettingsStore` 直接塞给 `V4TextTransformTool`

本窗没有去删这些 legacy 路径：

- `Sources/Core/Interaction/InteractionCoordinator.swift` 里普通听写 / 脑暴的旧 prompt 逻辑
- `Sources/Core/Magician/MagicianAgentModels.swift` 里的 legacy runtime prompt 逻辑

原因：

- 它们还不属于当前默认的 V4 选择改写主链
- 现在删会把非 V4 入口一起扯动，风险太大

## Window 08 时光机可挂载的 tool/action 点

这次已经把这些点准备好了，下一窗可以直接挂：

- `V4RunRequest.promptStack`
  - 可记录每轮 prompt 快照
- `V4RunRequest.modelSlots`
  - 可记录每轮槽位选择
- `V4ToHistoryBridge.executionTrace`
  - 已写入 `prompt_stack / model_slots` 摘要
- `V4AgentLoopEngine.resolvedRequest(...)`
  - 可做每轮 checkpoint
- `V4TextTransformTool`
  - 可记录 prompt 命中层、模型槽位、tool output 的对应关系

## 本窗新增测试

- `testPromptLayerOrderAndOverride`
- `testNowYouSeeMeRulesMapToPromptLayers`
- `testDisabledRuleNotInjected`
- `testModelSlotResolutionForAsrTextAgent`
- `testInvalidModelConfigReturnsStructuredError`
- `testAgentDefaultsToCliTextSlot`

## 本窗命令与结果

### 定向测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4PromptStackResolverTests -only-testing:PulseTypeTests/V4ModelSlotManagerTests
```

结果：

- 6 tests, 0 failures
- `V4PromptStackResolverTests` 全部通过
- `V4ModelSlotManagerTests` 全部通过

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
scripts/auto-ship.sh --message "core: unify v4 prompt stack and model slots" --files PulseType.xcodeproj/project.pbxproj Sources/App/AppModel.swift Sources/Core/Interaction/InteractionCoordinator.swift Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift Sources/Core/V4/Adapters/V4ProviderSettingsBridge.swift Sources/Core/V4/Adapters/V4SkillRuleBridge.swift Sources/Core/V4/Adapters/V4ToHistoryBridge.swift Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift Sources/Core/V4/Model/V4ModelSlotContracts.swift Sources/Core/V4/Model/V4ModelSlotManager.swift Sources/Core/V4/Model/V4ModelSlots.swift Sources/Core/V4/Prompt/V4PromptContracts.swift Sources/Core/V4/Prompt/V4PromptLayerProviders.swift Sources/Core/V4/Prompt/V4PromptStackResolver.swift Sources/Core/V4/ToolKernel/Tools/V4TextTransformTool.swift Sources/Core/V4/ToolKernel/V4ToolRegistry.swift Tests/V4PromptStackResolverTests.swift Tests/V4ModelSlotManagerTests.swift docs/v4/architecture/v4-master-architecture.md docs/v4-handoff/window-07.md
```

结果：

- 已完成 commit：`304f9a0`
- 已 push 到：`origin/codex/magician-agent-v2`
- 已覆盖安装：`/Applications/PulseType.app`
- 脚本默认跳过 test phase；本窗测试已在脚本前单独跑完并通过

## 下一窗第一条动作

- 先把 `prompt_stack / model_slots` 正式挂进时光机 checkpoint，确定每轮回放最小字段集
