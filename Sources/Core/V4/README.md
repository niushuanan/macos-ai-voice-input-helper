# PulseType V4

本目录是 V4 新内核的施工入口。目标很直接：UI 不动，功能不减，把旧的 `InteractionCoordinator + Magician*Runtime` 主链换成 claudecode 风格的新内核。

## 目录说明

- `AgentLoop/`
  V4 主循环。负责 turn state、lane 路由、下一步决策、loop events。
- `ToolKernel/`
  V4 工具层。负责工具注册、schema、权限、执行、结果格式。
- `Memory/`
  V4 记忆层。把本地历史与后续 checkpoint 变成可检索上下文。
- `Prompt/`
  V4 prompt 分层。统一拼 system、scene、dictionary、memory、tool-result。
- `Model/`
  V4 模型槽位层。继续吃 `asrConfig / textConfig / cliTextConfig`，但不再把业务调度散在旧 runtime 里。
- `TimeMachine/`
  V4 时光机。负责 timeline、checkpoint、回放摘要。

## 模块职责

### AgentLoop

- 接住普通听写、魔术先生、一口气全念对三条 lane。
- 根据模型结果与工具结果决定是否进入下一轮。
- 只对外发结构化事件，不直接耦合 UI。

### ToolKernel

- 每个工具都有固定输入 schema、权限规则、执行器、结果格式。
- 不再把 Calendar、Notes、Mail、Music、Feishu CLI 全塞进一个文件。

### Memory

- 读取旧历史，但不再只做列表页展示。
- 对 AgentLoop 提供 retrieval，而不是对 UI 暴露原始记录。

### Prompt

- 接住 `SkillRuleStore`、`AppScenePolicyStore`、`ASRDictionaryStore` 的数据。
- 形成唯一 prompt 组装入口。

### Model

- 统一处理三槽位与 fallback。
- 明确 lane 级、tool 级、brainstorm 级选模规则。

### TimeMachine

- 第一版先把 history 与 checkpoint 拉到同一个 timeline。
- 后续再接 replay、差异比对、回放摘要。

## 十窗推进顺序

1. Window 01：盘点当前模块，立 V4 蓝图与目录入口。
2. Window 02：落 `AgentLoop` 骨架与 lane bridge，接住旧入口。
3. Window 03：把 post-ASR 主流程移入 `AgentLoop`，压薄 `InteractionCoordinator`。
4. Window 04：落 `Prompt` 与 `Model` 骨架，停止在旧 runtime 内继续拼 prompt。
5. Window 05：落 `ToolKernel` adapters，替掉 `MagicianToolExecutor` 的总入口地位。
6. Window 06：迁移 native fast 路径，移走 `MagicianNativeRuntime` 主职责。
7. Window 07：迁移 agent path，替掉 `MagicianAgentRuntimeV3` 主循环。
8. Window 08：把 brainstorm 链路并入统一 loop，移走专用大分支。
9. Window 09：落 `Memory` 与 `TimeMachine`，迁移历史 schema。
10. Window 10：清理 V3 遗留代码，保留 UI 壳与桥接层。

## 当前约束

1. 不改 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/ControlCenterState.swift` 里的左侧分区定义。
2. 不改主键单击、主键长按、脑暴键双击的交互语义。
3. 不再向 `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的旧主链追加补丁。
