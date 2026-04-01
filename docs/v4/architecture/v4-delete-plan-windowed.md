# V4 分窗移除计划

说明：这里的“删”是指把旧主链移出运行面。凡是当前仍承担配置源、桥接、历史迁移职责的文件，在前置条件没达成前不动。

分类只有三种：`立刻删`、`替换后删`、`最终窗删`。

## Window 02

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | `selectedRuntime` 分派把 lane 分类、runtime 选择、history append 混在一起，是旧主链最核心耦合点。 | `Sources/Core/V4/AgentLoop/V4LaneRouter.swift` 与 `Sources/Core/V4/AgentLoop/V4LoopBridge.swift` 已接进 `handleWakeInput(context:)` 之后的主路径。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | `MagicianLane`、`MagicianLaneDecision`、`MagicianLaneClassifier` 应移入 V4 AgentLoop，不应继续挂在 Magician V3 文件里。 | V4 lane classifier 已覆盖 `nativeFast`、`agent`、混搭拒绝三类路径，并有测试覆盖。 |

## Window 03

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 立刻删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | 旧的 `outputSelectionRewrite(...)` 与 `outputSelectionRewriteV2(...)` 并存，会让新旧链路并排存在，后续极易再次长叉。 | V4 魔术先生桥接链已跑通，仓库内已无对旧 `outputSelectionRewrite(...)` 的调用。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | `processTranscriptionResult(...)`、`outputDictationTranscript(...)`、`outputBrainstormContext(...)` 目前仍是 lane 分支大本营。 | `V4AgentLoop` 已统一接住三个 lane 的 post-ASR 决策。 |

## Window 04

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianIntent.swift` | 这里的 `MagicianIntent` / `MagicianExecutionContext` 是旧工具协议；V4 应改成 typed `ToolCall` / `ToolResult`。 | `Sources/Core/V4/ToolKernel/V4ToolCall.swift` 与 `V4ToolResult.swift` 已成为工具层唯一输入输出。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/MagicianCommandSanitizer.swift` | 命令清洗逻辑属于 Prompt Layer，不该继续挂在 Interaction 层。 | `Sources/Core/V4/Prompt/*` 已接住命令预处理、scene 注入、rule 注入。 |

## Window 05

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` | 这是当前最明显的“巨石工具层”，Calendar / Notes / Mail / Music / Feishu CLI 全挤在同一文件，无法继续扩。 | `Sources/Core/V4/ToolKernel/Adapters/` 已把 Calendar、Notes、Mail、Music、Feishu CLI 全拆出，且 `MagicianAgentRuntimeV3` 不再直接调用此文件。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianFeatureModels.swift` | 若 V4 ToolRegistry 已有稳定 schema，旧 feature display/progress 文案应只留 UI 配置，不再驱动执行逻辑。 | V4 ToolRegistry 已成为唯一工具注册表；此文件只剩 UI 文案字段后再决定是否继续保留。 |

## Window 06

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | `MagicianNativeRuntime`、`MagicianNativePlanBuilder`、`MagicianAgentTextBackend` 属于旧计划层与旧文本后端，V4 要把这块改到 `AgentLoop + Prompt + Model`。 | V4 的 native fast 路径已能独立跑完文本处理、写回、历史落盘。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | 当前 `magicianExecutionTraceText(...)` 之前的数据拼装仍依赖旧 outcome 结构。 | V4 已统一产出 loop trace 与 tool trace，UI 历史页不再依赖 V3 outcome 格式。 |

## Window 07

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | `MagicianToolRegistryV3`、`MagicianSkillCatalogV3`、`MagicianSkillRouterV3`、`MagicianSkillRuntimeV3` 把“技能查找 + 技能执行 + 工具注册”绑成一团。 | `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift` 与 `Sources/Core/V4/Prompt/V4SkillLayer.swift` 已拆开技能检索与工具执行。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift` | `applyPipeline(...)`、`applyDictation(...)`、`applyRewriteOutput(...)` 这些执行函数不该继续留在存储层。 | V4 Prompt Composer 已把 skill rules 当配置源读取，旧 apply 流程已无调用。 |

## Window 08

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/BrainstormFallbackComposer.swift` | fallback 摘要与对话稿生成应并入 V4 Prompt/Memory，避免脑暴链路继续特化。 | V4 brainstorm lane 已有统一 fallback 生成器。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/BrainstormDurationProfileStore.swift` | 当前它只服务旧脑暴分支；V4 应把此类时长 profile 纳入 Model/TimeMachine 元数据。 | V4 已有针对脑暴 lane 的模型时长 profile 与迁移脚本。 |

## Window 09

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift` | 旧 flat JSON schema 不适合直接承担 retrieval 与 replay；V4 需要可检索、可回放的 memory schema。 | `Sources/Core/V4/Memory/V4HistoryBridge.swift` 与 `Sources/Core/V4/TimeMachine/V4TimeMachineStore.swift` 已完成历史迁移与兼容读取。 |
| 替换后删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/MemoryEntryTextResolver.swift` | 历史页文本解析高度绑定 V3 的 `SessionHistoryEntry` 字段命名。 | UI 已改读 V4 history view model，旧字段解析不再有调用。 |

## Window 10

| 分类 | 文件路径 | 删除理由 | 删除前置条件 |
| --- | --- | --- | --- |
| 最终窗删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | 当 V4 已接管主链后，这个文件里剩下的 V3 checkpoint、todo、guide、runtime helper 都会变成遗留负担。 | 仓库内已没有对 `MagicianNativeRuntime`、`MagicianAgentRuntimeV3`、`MagicianToolRegistryV3` 的调用；相关测试已迁到 V4。 |
| 最终窗删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | 该文件最终应只剩输入桥；若 V4 已完全接管，则旧 trace/event/history 拼装代码都应移走。 | `InteractionCoordinator` 已变成薄桥，且不再直接构造 `SessionHistoryEntry`。 |
| 最终窗删 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` | 若 ToolKernel adapters 全部稳定，保留整文件只会制造双入口。 | `Sources/Core/V4/ToolKernel/Adapters/` 全量上线，且 Git 全局搜索已找不到此文件的调用点。 |

## 当前判断

1. 真正该先拆的是 `InteractionCoordinator.swift` 与 `MagicianAgentModels.swift` 的耦合面。
2. `MagicianToolExecutor.swift` 必删，但必须等 ToolKernel adapters 落好再动。
3. `SkillRuleStore`、`ProviderSettingsStore`、`ASRDictionaryStore` 先不删文件，先把“执行逻辑”移走。
