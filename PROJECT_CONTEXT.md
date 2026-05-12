# Project Context

## 1. 这个项目是干什么的

PulseType 是一个 macOS 常驻语音助手，不是输入法本体。它的目标是让用户在任何 app 里都能用快捷键直接发起语音操作，把“说一句就能办完一件事”做成日常工作流。

当前产品已经形成三条清晰主线：

- 普通语音输入：录音后走 ASR，把结果直接写回当前编辑区域。
- 魔术先生：在长按或特定触发下进入 Agent 路径，执行改写、提醒、备忘录、邮件、音乐、CLI 等动作。
- 讨论整理：把连续口述整理成更适合继续分析或继续写作的结构化文本。

从现有代码和文档看，这个项目已经不是早期原型，而是处在“本地开发安装可用、能力继续深化”的阶段：有真实入口、有完整设置面板、有本地历史与诊断、有成体系测试，也已经把默认主链切到了 V4 Agent Runtime。

## 2. 代码结构是什么

这份仓库是一个标准的 macOS SwiftUI 应用，但产品逻辑明显重于界面壳层。

- `Sources/App`：应用入口和依赖装配。这里决定整个 app 怎么启动、菜单栏怎么挂、核心对象怎么注入。
- `Sources/Core`：业务内核，是仓库的主体。
  - `Session`：维护当前会话处于空闲、录音、转写、改写、写回等哪个阶段。
  - `Interaction`：主编排层，串起权限检查、录音、ASR、后处理、文本写回、魔术先生分流。
  - `Speech` / `Rewrite`：分别负责语音转写和文本生成模型的 provider 抽象、配置与调用。
  - `TextOutput`：负责把文本写回目标 app，属于最贴近用户成败体验的一层。
  - `Magician`：魔术先生的语义、能力开关、动作执行器、飞书 CLI 适配。
  - `V4`：新的 Agent 主链，包含 ToolKernel、Memory、Prompt、TimeMachine、Model Slot 等模块。
  - `Context` / `Permissions` / `Security` / `Storage` / `Diagnostics`：分别处理前台场景探测、权限、凭据、本地存储和诊断日志。
- `Sources/UI`：控制台与菜单栏 UI。这里承载首页、历史、词典、引擎、时光机、魔术先生、讨论整理、设置等界面。
- `Sources/Resources`：技能定义、文案资源、图标等静态内容。
- `Tests`：覆盖 V4 ToolKernel、TimeMachine、InteractionCoordinator、写回、快捷键、Provider、场景判断等大量行为测试。
- `scripts`：本地安装、诊断、测试、自动发布脚本。
- `docs`：产品原则、安装说明、架构设计、里程碑、V4 handoff 文档。

主数据流可以概括成：

1. 全局快捷键或菜单栏触发会话。
2. `InteractionCoordinator` 判断权限和当前 lane。
3. 录音结束后调用 ASR。
4. 根据模式进入普通写回、讨论整理，或者魔术先生 V4 Agent。
5. 最终把结果写入目标 app，同时把历史、日志、诊断信息落到本地。

## 3. 关键入口在哪里

- `Sources/App/PulseTypeApp.swift`
  - 应用主入口。
  - 定义了两个最重要的产品壳层：控制中心窗口和菜单栏入口。
- `Sources/App/AppModel.swift`
  - 真正的依赖装配中心。
  - 这里把 `SessionStore`、`InteractionCoordinator`、`GlobalHotkeyService`、`ProviderSettingsStore`、`LocalHistoryStore`、`V4MagicianRuntimeAdapter` 等核心对象接起来。
- `Sources/Core/Interaction/InteractionCoordinator.swift`
  - 运行时总调度器。
  - 负责处理开始录音、停止录音、讨论整理、魔术先生触发、转写后的后续路径，是“产品是否顺手”的关键代码。
- `Sources/UI/ControlCenterState.swift`
  - 定义控制中心的主分区，能直接看出当前产品有哪些核心页面：`首页`、`历史`、`词典`、`引擎`、`时光机`、`魔术先生`、`讨论整理`、`设置`。
- `Sources/UI/MenuBarMenuView.swift`
  - 菜单栏操作面板。
  - 这里能看出产品不是纯配置页，而是支持直接从菜单栏开始听写、开始讨论整理、取消会话、查看诊断状态。
- `Sources/Core/V4`
  - 新主链的落点。
  - 其中 `ToolKernel` 负责工具注册、权限和证据，`Memory` 负责本地历史转可检索上下文，`TimeMachine` 负责时间解析和提醒，属于魔术先生能力体系的真正底座。

## 4. 最近改了什么

### 2026-05-12 音乐快路径提速第一版

- 本次任务：针对魔术先生播放音乐体感偏慢的问题，先优化 `music_fast` 里最容易压时延、又不容易引入行为回退的两段：明确点歌的选曲决策，以及已建立资料库顺序队列后的重复点播。
- 改了哪些文件：
  - `Sources/Core/V4/ToolKernel/Tools/V4MusicControlTool.swift`
  - `Tests/V4ToolExecutionScenarioTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 给音乐工具新增“本地高确定度短路”：当命令里已经能唯一确定歌曲或专辑时，先直接走本地精确匹配，不再默认先请求选曲 LLM。
  - 给资料库顺序队列新增会话记忆：记录当前这轮已经锁定的 `orderedTrackIDs` 和对应 revision。
  - 当用户还在这轮同一份资料库顺序队列里点播另一首歌时，优先直接在现有 `PulseType Library Order Queue` 中跳到目标曲目，不再每次都清空并重建整条播放列表。
  - 补了 3 个定向测试，覆盖“唯一精确命中直接短路”“用歌手信息打破同名歌曲歧义”“仍有歧义时不冒进短路”。
- 为什么这样改：
  - 真实 trace 显示 `music_tool_ms` 明显大于 `router_llm_ms`，瓶颈主要不在入口路由，而在音乐工具内部。
  - 当前实现为了稳，会在很多点歌请求里先走一次选曲 LLM，再重建整条资料库顺序队列；这对“周杰伦的跨时代”这种本来就很明确的请求来说太重了。
  - 这次先只做“本地已经足够确定时才跳过 LLM”“当前队列就是我们刚建好的那套顺序时才复用”，可以先换到更快的热路径，同时把误播风险压住。
- 影响了哪些模块：
  - 影响 `apple.music.control` 的歌曲选择策略、资料库顺序队列复用逻辑，以及对应的音乐工具测试。
  - 不影响普通听写、讨论整理、非音乐工具，也没有改动 `music_fast` 的外层交互结构。

### 2026-05-12 外部真实流式写回第一版

- 本次任务：基于 `docs/streaming-writeback-research-and-prompt-matrix.md`，把普通听写的 DeepSeek streaming 从“只在 HUD / 菜单栏里预览”推进到“在外部输入框里尽早看到稳定片段”。
- 改了哪些文件：
  - `Sources/Core/TextOutput/TextOutputCoordinator.swift`
  - `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Tests/InteractionCoordinatorTests.swift`
  - `Tests/SessionStoreTests.swift`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 给 `TextOutputRequest` 增加 `writeMode`，把最终写回和流式 chunk 写回区分开。
  - 流式 chunk 写回不再长期污染剪贴板，也不会在 AX 失败后继续反复走 `Command+V`；第一版只在 `AX` 条件足够稳时才连续推进外部文本。
  - 新增“稳定前缀推进器”和“流式写回控制器”，在 `InteractionCoordinator` 的 `onPartialText` 回调里按累计快照计算可确认片段，边更新预览边把稳定内容增量写进外部 app。
  - 最终阶段不再盲目整段重写，而是按已写前缀决定“只补尾巴”或“直接结束”；如果最终文本与已写前缀不一致，会把完整结果放进剪贴板并给出提示。
  - 补了定向测试，覆盖稳定片段多次追加、全文已覆盖时跳过最终整段写入、chunk 失败后退回普通一次性写回、以及 streaming chunk 不走粘贴兜底。
- 为什么这样改：
  - 用户要的是实际使用时在外部输入框里看到内容逐步出现，而不是只在 PulseType 自己的界面里看到预览。
  - macOS 上真正可控的近期路线不是直接重做输入法，而是利用现有 AX 写回链路，把“已经足够稳的前缀”尽早推进到目标 app，同时保留最终一致性保护。
- 影响了哪些模块：
  - 影响普通听写的 DeepSeek 后处理链路、外部文本写回策略、会话结束时的写回判定，以及对应的单元测试。
  - 当前只作用于普通听写的文本整理 streaming，不影响魔术先生、讨论整理，也没有把高风险目标（如 `Codex` / `Slack` / `Discord` / `code` 系）强行纳入连续外写。

### 2026-05-12 外部流式写回调研与 Prompt 生效矩阵

- 本次任务：针对“流式输出必须在真实外部使用场景里体现”这个目标，补了一份面向当前仓库的技术调研与功能矩阵文档，顺便把现有 prompt 的真实生效边界梳理清楚。
- 改了哪些文件：
  - `docs/streaming-writeback-research-and-prompt-matrix.md`
  - `PROJECT_CONTEXT.md`
- 改了什么：
  - 新增文档，系统比较了 macOS 上两条路线：`Accessibility 增量写回` 与 `InputMethodKit 真输入法`。
  - 结合 Apple 官方文档和 GitHub 上公开的 macOS dictation 项目，给出更适合 PulseType 当前架构的方案：先做“稳定片段增量写回到外部 app”，而不是只做 HUD 内部预览，也不是立刻大改成输入法。
  - 在同一份文档里整理了“功能 x prompt 生效矩阵”，明确哪些链路真正会用到 `ASR 词典`、`口语过滤`、`systemPrompt`、`appPrompt`、内部场景 prompt 与 DeepSeek 文本模型。
- 为什么这样改：
  - 上一版虽然已经有模型侧 streaming，但流式只停留在内部状态与 HUD / 菜单栏，不足以体现真实外部场景价值。
  - 当前仓库里 prompt 生效边界并不统一，如果不先做矩阵梳理，后续做流式外写和 prompt 扩展时很容易误判。
- 影响了哪些模块：
  - 这次没有改运行时代码，影响的是产品判断、后续技术方案和 prompt 治理方式。
  - 后续如果继续推进外部流式写回，这份文档会直接决定优先走 `AX 稳定片段增量写回` 还是单独开 `InputMethodKit` 路线。

### 2026-05-12 DeepSeek 后处理流式输出第一版

- 本次任务：为普通听写增加 “ASR 完成后 -> DeepSeek 文本整理流式预览 -> 完整生成后一次性写入当前 app” 的第一版能力，并结合 macOS 的实际写回边界控制实现范围。
- 改了哪些文件：
  - `Sources/Core/Rewrite/RewriteProvider.swift`
  - `Sources/Core/Rewrite/OpenAITextGenerationProvider.swift`
  - `Sources/Core/Session/SessionStore.swift`
  - `Sources/Core/Interaction/InteractionCoordinator.swift`
  - `Sources/UI/StatusPulseHUDController.swift`
  - `Sources/UI/MenuBarStatusView.swift`
  - `Tests/SessionStoreTests.swift`
  - `Tests/InteractionCoordinatorTests.swift`
  - `Tests/OpenAIProviderAdapterTests.swift`
- 改了什么：
  - 给文本生成层新增 streaming 协议，`OpenAITextGenerationProvider` 现在可以通过 SSE 读取增量文本，并兼容 DeepSeek V4 的 `stream: true` 返回。
  - 给 `LLMDictationPostProcessor` 新增流式处理入口，直接把 DeepSeek 的增量正文往上抛，而不是只等最终完整文本。
  - `SessionStore` 新增 `liveOutputPreview` 和普通听写的整理中状态；HUD 与菜单栏现在可以在整理阶段展示实时片段。
  - `InteractionCoordinator` 在普通听写命中模型整理时，会先进入整理阶段，边接流式文本边更新 UI，等最终文本完成后仍然走原来的单次写入链路。
  - 新增测试覆盖：SSE 解析、听写整理流式预览、会话状态清理。
- 为什么这样改：
  - DeepSeek 官方接口已经支持 SSE 流式输出，但 macOS 跨 app 写入依赖 Accessibility 与粘贴兜底，不适合把每个增量 token 直接写进外部编辑器。
  - 第一版把流式能力限制在 PulseType 自己的 HUD / 菜单栏预览里，能明显改善等待体感，同时避免外部 app 光标抖动、误覆盖、选区错位这些系统级风险。
- 影响了哪些模块：
  - 影响文本模型 provider 抽象、普通听写后处理链路、会话状态机、HUD 标题解析、菜单栏提示与对应测试。
  - 目前只作用于普通听写的文本整理链路，不影响魔术先生、讨论整理，也不改变最终写回仍为一次性写入的主策略。

### 2026-05-12 DeepSeek V4 切换

- 本次任务：把默认文本模型与 CLI 文本模型从 `deepseek-chat` 切到 `deepseek-v4-flash`，并核对 DeepSeek 官方关于 V4 与流式输出的接口变化。
- 改了哪些文件：
  - `Sources/Core/Speech/SpeechProvider.swift`
  - `Sources/Core/Speech/ProviderSettingsStore.swift`
  - `Sources/Core/Rewrite/OpenAITextGenerationProvider.swift`
  - `Sources/Core/Speech/SpeechConnectionTesters.swift`
  - `Tests/ProviderSettingsStoreTests.swift`
  - `Tests/V4ModelSlotManagerTests.swift`
  - `Tests/OpenAIProviderAdapterTests.swift`
  - `README.md`
  - `docs/usage.md`
  - `docs/api-key-setup.md`
  - `docs/pulsetype-99637ae-全项目功能与技术链路详解.md`
- 改了什么：
  - 默认 rewrite / CLI 模型名改为 `deepseek-v4-flash`。
  - 对已保存的 `deepseek-chat` 兼容配置做启动迁移，避免用户升级后仍停在旧别名。
  - 对发往 DeepSeek V4 的 OpenAI-compatible 文本请求显式附带 `thinking: disabled`，保持原先 `deepseek-chat` 的非思考时延与输出形态。
  - 补了请求编码与配置迁移测试，并同步更新用户文档。
- 为什么这样改：
  - DeepSeek 官方已把 `deepseek-v4-flash` 作为正式模型名，`deepseek-chat` 只是过渡别名且将停用。
  - 如果只改模型名、不显式关闭 thinking，当前“听写后清理 / 改写 / CLI 文本”链路会悄悄变成思考模式，体感会更慢，也不利于后续做稳定的流式正文输出。
- 影响了哪些模块：
  - 模型默认配置、配置迁移、文本模型连通性测试、所有基于 `OpenAITextGenerationProvider` 的文本后处理链路。
  - 后续若要做“ASR 完成后，DeepSeek 处理结果流式预览，再一次性写回当前 app”，这次改动已经把模型名和非思考模式前提对齐。

### 初始建档

- 本次任务：首次补建当前项目的 `PROJECT_CONTEXT.md`，并基于真实代码与文档完成产品梳理。
- 改了哪些文件：`PROJECT_CONTEXT.md`
- 改了什么：新增项目级上下文文档，记录产品用途、代码结构、关键入口和本次建档信息。
- 为什么这样改：这个仓库已经有完整代码和稳定结构，按项目规则应先建立项目档案，方便后续任何新对话都先读真实上下文再继续工作。
- 影响了哪些模块：不影响运行时代码；影响的是后续协作、阅读和任务交接方式。
