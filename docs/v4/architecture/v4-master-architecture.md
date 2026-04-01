# V4 总架构蓝图

目标：UI 不动，交互入口不动，功能边界不减；把当前 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 里那条旧主链，换成 claudecode 风格的统一内核。

## V4 目标目录

```text
/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/
├── AgentLoop/
│   ├── V4AgentLoop.swift
│   ├── V4TurnState.swift
│   ├── V4LaneRouter.swift
│   ├── V4LoopEvent.swift
│   └── V4LoopBridge.swift
├── ToolKernel/
│   ├── V4ToolKernel.swift
│   ├── V4ToolRegistry.swift
│   ├── V4ToolCall.swift
│   ├── V4ToolResult.swift
│   ├── V4ToolPermission.swift
│   └── Adapters/
├── Memory/
│   ├── V4MemoryRecord.swift
│   ├── V4MemoryIndex.swift
│   ├── V4MemoryRetriever.swift
│   └── V4HistoryBridge.swift
├── Prompt/
│   ├── V4PromptLayer.swift
│   ├── V4PromptComposer.swift
│   ├── V4SceneLayer.swift
│   ├── V4SkillLayer.swift
│   └── V4DictionaryLayer.swift
├── Model/
│   ├── V4ModelSlot.swift
│   ├── V4ModelSlotResolver.swift
│   ├── V4ModelRequest.swift
│   └── V4ModelResponse.swift
└── TimeMachine/
    ├── V4Checkpoint.swift
    ├── V4TimeMachineStore.swift
    ├── V4TimelineQuery.swift
    └── V4ReplaySummary.swift
```

## 模块职责

### `Sources/Core/V4/AgentLoop/*`

- 接住三个 lane：普通听写、魔术先生、一口气全念对。
- 管理 turn state、max turns、当前 phase、下一步动作。
- 接住 `ToolKernel` 的结构化结果，再决定是否继续下一轮。
- 对外只发结构化 loop events，UI 不直接碰内部细节。

### `Sources/Core/V4/ToolKernel/*`

- 统一注册工具，不再把工具逻辑绑在 `MagicianToolExecutor.swift` 这一个巨型文件里。
- 每个工具有固定 schema、权限规则、执行器、结果格式。
- `Feishu CLI`、Mail、Calendar、Notes、Music、TextOutput 都走同一层。
- 支持 pre-tool / post-tool 钩子，方便后续接 telemetry、trace、回放。

### `Sources/Core/V4/Memory/*`

- 从 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift` 读取历史记录。
- 把 `SessionHistoryEntry` 变成可检索的 memory records。
- 面向 V4 提供 retrieval，而不是只给 UI 列表页看。

### `Sources/Core/V4/Prompt/*`

- 合并当前散落在以下文件里的 prompt 输入源：
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift`
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Context/AppScenePolicyStore.swift`
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ASRDictionaryStore.swift`
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Context/ContextDetector.swift`
- 形成统一 prompt layering：system / scene / dictionary / memory / lane / tool-result。

### `Sources/Core/V4/Model/*`

- 继续使用 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ProviderSettingsStore.swift` 里的三槽位配置。
- 但真正的槽位解析、lane 选模、tool step 选模、fallback，不再散在旧 runtime 内。
- `asrConfig`、`textConfig`、`cliTextConfig` 变成 V4 的输入，不再直接决定业务分支。

### `Sources/Core/V4/TimeMachine/*`

- 第一版数据源来自两处：
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift`
  - `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 里的 `MagicianAgentCheckpointStore`
- 提供 timeline、checkpoint、回放摘要，不直接绑 UI 形态。
- 当前窗口先立目录与命名，不急着做界面。

## 数据流

### 统一主线

1. 麦克风输入进入 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Hotkey/GlobalHotkeyService.swift`。
2. `GlobalHotkeyService` 继续调用 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 的公开入口：
   - `handleWakeInput(context:)`
   - `handleBrainstormInput()`
   - `handleStopInput()`
3. `InteractionCoordinator` 在 V4 里只做入口桥接：录音、ASR 请求、把结果送入 `V4AgentLoop`。
4. `V4AgentLoop` 根据 lane 与上下文做分类：
   - `directDictation`
   - `selectionRewrite`
   - `brainstormDiscussion`
5. `V4PromptComposer` 组装 prompt layers，`V4MemoryRetriever` 拉相关历史，`V4ModelSlotResolver` 选模型槽位。
6. 模型返回 tool plan 或文本结果；若有工具调用，交给 `V4ToolKernel`。
7. `V4ToolKernel` 产出结构化 `V4ToolResult`；`V4AgentLoop` 决定是否继续下一轮。
8. 最终结果写回：
   - 文本写回仍经 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/TextOutput/TextOutputCoordinator.swift`
   - 历史仍先落到 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift`
   - Trace / checkpoint 同步进入 `TimeMachine`

### lane 视角

- 普通听写：麦克风 -> ASR -> Prompt Layer（词典 + scene + spokenFilter）-> `V4AgentLoop` 快速文本链 -> 写回 / 历史
- 魔术先生：麦克风 -> ASR -> lane 分类 -> `V4AgentLoop` 多轮计划 -> `V4ToolKernel` -> 历史 / 时光机 / 状态回推
- 一口气全念对：麦克风 -> ASR -> lane 分类 -> `V4AgentLoop` 上下文整理链 -> 输出摘要 / 对话稿 / 历史

## UI 不变但内核替换的边界规则

1. 左侧分区继续固定在 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/ControlCenterState.swift` 里的 `home / memory / dictionary / skills / model / magician / agentBrainstorm / settings`。
2. `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/SettingsView.swift` 里的 page 入口继续保留：`memoryPage`、`dictionaryPage`、`skillsPage`、`modelPage`、`magicianPage`、`agentBrainstormPage`、`settingsPage`。
3. 交互入口继续保留当前热键语义：
   - 主键单击：普通听写
   - 主键长按：魔术先生
   - 脑暴键双击：一口气全念对
4. `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Session/SessionStore.swift` 保留为 UI-facing 状态壳，但不再持有核心业务判断。
5. `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 以后只做入口桥、状态桥、错误桥，不再继续长出 V4 业务分支。
6. 禁止继续把新逻辑堆进 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的 `MagicianNativeRuntime` / `MagicianAgentRuntimeV3` 主链。
7. `ProviderSettingsStore`、`SkillRuleStore`、`ASRDictionaryStore`、`LocalHistoryStore` 先留作桥接层；等 V4 跑稳后，再把执行逻辑从旧文件内移走。
8. 时光机先做内核能力，再决定 UI 入口放在哪；当前窗口不改左侧菜单。

## 当前架构判断

1. 最先该拆的是旧主链，不是页面。
2. `InteractionCoordinator` 应变薄，`V4AgentLoop` 应变厚。
3. `MagicianToolExecutor.swift` 不该再当系统级工具总入口；V4 要把它拆成 ToolKernel adapters。
