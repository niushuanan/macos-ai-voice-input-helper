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
