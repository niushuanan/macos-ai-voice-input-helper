# PulseType（99637ae）全项目功能与技术链路详解

> 版本基线：`99637ae`  
> 代码目录：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法`

## 1. 这个产品现在到底是啥

PulseType 是一个 macOS 常驻语音助手，形态是：

- 一个主窗口（控制台）
- 一个 menu bar 常驻入口
- 一个全局快捷键驱动的语音会话引擎

它不是输入法内核，也不是浏览器插件。它的主思路是：

1. 用全局快捷键拉起会话
2. 录音
3. ASR 转文本
4. 按 lane 分流（普通听写 / 魔术先生 / 一口气全念对）
5. 执行文本处理或 tool 调用
6. 写回当前 app（AX 直写或粘贴兜底）
7. 记录完整历史与证据轨迹

---

## 2. 顶层架构总览

### 2.1 目录与体量

- `Sources/App`：4 文件，约 710 行
- `Sources/UI`：12 文件，约 5871 行
- `Sources/Core`：116 文件，约 39747 行
- `Tests`：51 文件，约 14559 行
- `scripts`：10 文件，约 747 行
- `docs`：37 文件，约 4243 行

### 2.2 运行时主干

- App 入口：`Sources/App/PulseTypeApp.swift`
- 依赖装配：`Sources/App/AppModel.swift`
- 生命周期策略：`Sources/App/AppDelegate.swift` + `Sources/App/AppRuntimePolicy.swift`
- 编排核心：`Sources/Core/Interaction/InteractionCoordinator.swift`
- 状态机：`Sources/Core/Session/SessionStore.swift`
- V4 runtime：`Sources/Core/V4/*`
- 旧版 Magician runtime：`Sources/Core/Magician/*`（仅 debug 兜底）

---

## 3. 用户可见功能（按页面）

页面定义在 `Sources/UI/ControlCenterState.swift` 的 `DesktopSection`：

1. 首页
2. 记忆
3. 词典
4. 模型
5. 时光机
6. 魔术先生
7. 一口气全念对
8. Now you see me
9. 设置

以下每页都在 `Sources/UI/SettingsView.swift` 实现。

### 3.1 首页

- 展示产品简介
- 展示 4 个历史指标：
  - 历史对话时长
  - 历史输入字数
  - 平均速度（字/分钟）
  - 总计节省时间
- 数据来自 `LocalHistoryStore.lifetimeSnapshot`

### 3.2 记忆

- 按过滤器查看历史：全部 / 普通听写 / 魔术先生 / 一口气全念对 / 失败
- 支持复制：主文本、原文、命令、执行链路、执行解读
- 支持删除单条
- 支持两种清理：
  - 仅清理记忆记录
  - 深度清理（历史 + 时光机 + 诊断日志等）

### 3.3 魔术先生

- 展示 V4 主链状态
- 权限 scope 开关（文本处理 / 原生动作 / skill）
- 原生动作能力项（日历、本地文档、邮件、音乐）
- Feishu CLI 可用性与健康诊断
- 邮箱名库管理入口
- 当前版本提示：本地 skill 文件暂不做页面上传

### 3.4 Now you see me

- 规则层设置（spoken filter、system prompt、按应用策略）
- 每个 app 可单独配置 app prompt
- 支持自动扫描本机 app 列表并添加策略

### 3.5 模型

三槽位配置：

1. ASR
2. 文本处理
3. CLI Agent 文本槽位

每个槽位都可改：

- provider
- baseURL
- model
- API key

并且都带连通测试入口。

### 3.6 词典

- 每行一个词条
- 保存后立刻作用到 ASR 请求
- 支持专业词、专名

### 3.7 一口气全念对

- 展示功能说明
- 展示当前模型实测上限与推荐时长
- 支持双击修饰键触发配置
- 与普通听写共用快捷键系统，但 lane 不同

### 3.8 时光机

- 查看本地时间类记录
- 查看状态统计（总数/已定时/失败）
- 查看每条 item 的创建时间、提醒时间、标签

### 3.9 设置

- 主键设置（单击/长按语义）
- 一口气全念对触发键
- 取消键说明（Esc）
- 权限中心（麦克风 / 辅助功能）
- 本地运行信息与检测动作

---

## 4. 三条核心业务链路

## 4.1 普通听写链路

代码入口：`InteractionCoordinator.handleWakeInput(context: .dictationTap)`

1. 权限检查（至少麦克风）
2. `SessionStore` 进 `listening`
3. `AudioCaptureService` 录音
4. 再次触发主键后 stop，进 `transcribing`
5. `SpeechProviderRegistry` 找 ASR provider
6. 得到 transcript 后按策略决定：
   - 只做 ASR
   - ASR + 文本后处理（`DictationPostProcessor`）
7. `TextOutputCoordinator.write` 写入目标 app
8. 记历史 `LocalHistoryStore.append`
9. HUD 与 menu bar 状态同步

关键点：

- 写回优先 AX，失败再走 Command+V
- 仍失败时至少保留 clipboard
- 全链路打点进 `speech-pipeline.log` 与 `telemetry.log`

## 4.2 魔术先生链路（当前默认 V4）

入口：主键长按（>=180ms）

1. 录音 -> ASR
2. 命令预处理：`MagicianCommandSemanticPreprocessor`
3. 语义路由：`MagicianSemanticLaneRouter` 判定
   - `native_fast`（音乐单动作）
   - `agent`（一般走 V4 planner）
4. runtime 路由：`V4RuntimeSwitchStore`
   - 默认 `.v4`
   - 仅在 debug 环境变量/开关开启时可走 legacy
5. V4 执行：
   - `V4AgentLoopEngine`：turn 循环
   - `V4PlannerLLM`：步骤规划
   - `V4ToolKernel`：工具执行与证据校验
   - `V4VerifierDefault`：核验
   - `V4PostStepDeciderPlannerDriven`：后续决策
6. 事件桥接：
   - `V4ToSessionStoreBridge` -> HUD/状态
   - `V4ToHistoryBridge` -> 历史与执行链路文本

如果命中 `music_fast`：

- 走 `MusicFastExecutor`
- 内部仍调用 `V4MusicControlTool`
- 产出 execution trace + interpretation
- 写回历史

## 4.3 一口气全念对链路

入口：双击修饰键（<=350ms）

1. 录音时长按 profile 自动守卫
2. stop 后 ASR
3. `BrainstormContextComposer` 做讨论整理
4. 结果写入目标 app + clipboard
5. 同时把对话原文与整理结果写历史

并且有独立的 `BrainstormDurationProfileStore` 探测模型可用时长。

---

## 5. 魔术先生逻辑深挖（你重点关心的部分）

这版（`99637ae`）里，魔术先生实际是“双层结构”：

1. `InteractionCoordinator` 负责入口、上下文、桥接、历史
2. `Core/V4` 负责 planner/tool/verifier 的运行内核

### 5.1 Lane 语义判定

`MagicianSemanticLaneRouter` 用 agent 槽位模型做 JSON 路由决策，字段含：

- lane：`native_fast | agent`
- path：`music_fast | planner_v4`
- selection_mode：`none | optional | required`
- normalized_intent / normalized_query

默认策略是：

- 多步骤外部动作 -> `agent`
- 音乐单动作优先 `music_fast`
- 不足/异常时 fallback 到 `agent + planner_v4`

### 5.2 V4 Planner 与 Tool Kernel

`V4AgentLoopEngine.run` 里每轮做：

1. `planner.plan`
2. 对每个 step：
   - `toolRequested`
   - `tool.execute`
   - `toolFinished`
   - `verifier.verify`
   - `postStepDecider.decide`
3. 直到 `completed / waitingForUser / failed`

内核支持：

- step retry（按 manifest policy）
- 结构化 runtime events
- max turn 限制

### 5.3 Tool 体系

`V4ToolRegistry.live` 注册工具：

- `text.transform`
- `md.pipeline`
- `shell.command.run`
- `applescript.run`
- `apple.calendar.create`
- `apple.notes.create`
- `apple.mail.compose`
- `apple.music.control`
- `feishu.cli`
- `time_machine.create`
- `time_machine.remind`（有 timeMachineService 时）

每个 tool 有：

- input schema
- permission scope
- retry policy
- evidence policy

### 5.4 “防伪成功”机制（代码层）

- `V4ToolEvidencePolicy` 按 `requiredKeys` 做结构化证据检查
- `V4ToolManifest` 可为不同 tool 定 `structured` 证据要求
- `FeishuResultVerifier` 对关键写动作要求 event_id/message_id/doc_id 等
- `V4PermissionGate` 先查 scope toggle，未开则直接 deny

### 5.5 仍存在的结构现实

- `InteractionCoordinator.swift` 体量很大，编排逻辑集中
- legacy runtime 代码仍在仓（`MagicianNativeRuntime`, `MagicianAgentRuntimeV3`）
- 但默认路由是 V4；legacy 仅 debug 开关可触发

---

## 6. 模型与 provider 体系

### 6.1 provider 类型

`ProviderType`：

- `openAI`
- `openAICompatible`
- `dashScopeQwenASR`
- `localSenseVoice`

### 6.2 三槽位

`ProviderSettingsStore` 持久化三套配置：

- `asrConfig`
- `textConfig`
- `cliTextConfig`

默认模型倾向：

- ASR：`qwen3-asr-flash` 或 `whisper-1`
- 文本：`deepseek-v4-flash`
- CLI 文本：`deepseek-v4-flash`

### 6.3 接口协议

- ASR：
  - OpenAI 兼容：`/v1/audio/transcriptions`
  - DashScope：`/api/v1/services/aigc/multimodal-generation/generation`
- 文本：`/v1/chat/completions`

`OpenAIEndpointResolver` 避免 baseURL 出现 `/v1/v1`。

---

## 7. 写回链路（TextOutput）

`AccessibilityTextOutputCoordinator` 负责：

1. 抓取当前焦点上下文
2. 先走 AX 直写（`accessibilitySelectionReplacement`）
3. 失败时走粘贴兜底（`pasteFallbackCommandV`）
4. 极端场景仅 clipboard（`clipboardOnly`）

返回结构 `TextOutputResult` 会写进历史，并影响 UI 状态文案。

---

## 8. 历史、记忆、时光机

### 8.1 历史

`LocalHistoryStore` 记录：

- 每次会话输入/输出
- lane 与状态
- provider/model
- 魔术先生 trace / evidence / interpretation
- audio 时长
- applied skills

### 8.2 统计

首页“字数、时长、速度、节省时间”来自：

- `lifetime-stats-v1.json`
- 速度口径：仅有真实 `audioDurationSeconds` 的样本
- 节省时间：按 `typingBaselineCPM=60` 粗略估值

### 8.3 时光机

- `V4TimeMachineService` 处理“记一下/提醒我”
- `V4TimeParser` 做时间解析
- `V4ReminderScheduler` 负责本地提醒调度
- 记录落地到 `History` 目录下 time machine 存储文件

### 8.4 V4 Memory

- `V4MemoryEngine` 用倒排索引 + 字段权重 + 时间衰减打分
- 查询输入由 `V4MemoryQueryPlannerInputAdapter` 组装
- 命中结果注入 `V4RunRequest.memoryHints`

---

## 9. 快捷键、状态与 HUD

### 9.1 快捷键状态机

`GlobalHotkeyService` 内部有两套状态机：

- `WakeModifierPressStateMachine`（单击 vs 长按）
- `ModifierDoubleTapStateMachine`（双击）

语义：

- 单击主键：普通听写 start/stop
- 长按主键：魔术先生
- 双击脑暴键：一口气全念对
- Esc：cancel

### 9.2 状态流

`SessionStore` phase：

- idle
- listening
- transcribing
- rewriting
- inserting
- cancelled
- error

`StatusPulseHUDController` 根据 phase + progressHint 显示 HUD 文案和进度动画。

menu bar 图标由 `MenuBarStatusView` 实时跟 phase 变化。

---

## 10. 权限、安全、本地存储

### 10.1 权限

`PermissionsCenter` 管理：

- 麦克风
- 辅助功能

并带：

- 首次自动请求逻辑
- 系统设置跳转
- runtime 签名/路径诊断

### 10.2 密钥

`CredentialStoreFactory` 默认走 `LocalFileProviderCredentialStore`：

- 文件：`~/Library/Application Support/PulseType/Credentials/credentials.v1.json`
- 可兼容迁移旧 Keychain 项

### 10.3 本地目录

`LocalStore` 统一目录：

- `History`
- `Diagnostics`
- `Credentials`
- `TemporaryAudio`
- `Runtime/SenseVoice`

---

## 11. 工程脚本与发布链路

`scripts` 里关键脚本：

1. `install-local-app.sh`
   - 构建 -> 覆盖安装 `/Applications/PulseType.app` -> ad-hoc 签名 -> 启动
2. `doctor-runtime.sh`
   - 进程、签名、权限、偏好、凭据、lsregister 诊断
3. `repair-local-runtime.sh`
   - 清旧路径、tcc reset、清旧 keychain 兼容项
4. `test-magician-fast.sh`
   - 快速测试集（可 `--full`）
5. `auto-ship.sh`
   - 按参数执行 test/commit/push/install
6. `secret-scan.sh`
   - 提交前敏感串扫描

---

## 12. 测试覆盖现状

`Tests` 共 51 个 test 文件。

主类目：

- V4：13
- Magician：8
- Interaction：2
- Brainstorm：2
- Feishu：2
- App/Session/Hotkey/Permission/Provider/Rewrite/Local 等多模块都有单测

重点测试对象包含：

- `V4AgentLoopEngine`
- `V4ToolKernel`
- `V4PlannerLLM`
- `V4MDPipelineTool`
- `V4TimeMachineService`
- `FeishuCLIProvider` / `FeishuResultVerifier`
- `InteractionCoordinator`（含 V4 routing）
- `LocalHistoryStore`
- `ProviderSettingsStore`

---

## 13. 这版魔术先生的真实逻辑总结（简明版）

一句话：

- 入口在 `InteractionCoordinator`
- 默认执行核在 `Core/V4`
- tool 全部经 `V4ToolKernel`
- 结果都要进 history trace
- legacy runtime 仅 debug 兜底，不是默认链路

所以你现在看到的“魔术先生”，不是旧版硬编码分支，而是 V4 planner + tool kernel + verifier 的统一主链。

---

## 14. 全板块清单（防遗漏）

以下是按目录枚举的全文件附录，保证每个板块都在文档里有记录。


### 14.1 Sources/App
- `Sources/App/AppDelegate.swift`
- `Sources/App/AppModel.swift`
- `Sources/App/AppRuntimePolicy.swift`
- `Sources/App/PulseTypeApp.swift`

### 14.2 Sources/UI
- `Sources/UI/ControlCenterState.swift`
- `Sources/UI/HomeStatsFormatter.swift`
- `Sources/UI/MailAddressBookViews.swift`
- `Sources/UI/MemoryEntryTextResolver.swift`
- `Sources/UI/MenuBarMenuView.swift`
- `Sources/UI/MenuBarStatusView.swift`
- `Sources/UI/ModifierCaptureButton.swift`
- `Sources/UI/ModifierCaptureStateMachine.swift`
- `Sources/UI/SceneAppDiscovery.swift`
- `Sources/UI/SettingsView.swift`
- `Sources/UI/SettingsViewComponents.swift`
- `Sources/UI/StatusPulseHUDController.swift`

### 14.3 Sources/Core
- `Sources/Core/.DS_Store`
- `Sources/Core/Audio/AudioCaptureService.swift`
- `Sources/Core/Context/AppScenePolicyStore.swift`
- `Sources/Core/Context/ContextDetector.swift`
- `Sources/Core/Diagnostics/DiagnosticsCenter.swift`
- `Sources/Core/Diagnostics/SpeechPipelineLogger.swift`
- `Sources/Core/Diagnostics/WorkflowTelemetry.swift`
- `Sources/Core/History/LocalHistoryStore.swift`
- `Sources/Core/Hotkey/GlobalHotkeyService.swift`
- `Sources/Core/Hotkey/HotkeyNames.swift`
- `Sources/Core/Hotkey/HotkeyStateStore.swift`
- `Sources/Core/Interaction/BrainstormDurationProfileStore.swift`
- `Sources/Core/Interaction/BrainstormFallbackComposer.swift`
- `Sources/Core/Interaction/InteractionCoordinator.swift`
- `Sources/Core/Interaction/InteractionCoordinatorTypes.swift`
- `Sources/Core/Interaction/MagicianCommandSanitizer.swift`
- `Sources/Core/Interaction/MagicianSemanticLaneRouter.swift`
- `Sources/Core/Interaction/SpeechTranscriptionErrorPresentation.swift`
- `Sources/Core/Magician/CLI/FeishuCLIErrorMapper.swift`
- `Sources/Core/Magician/CLI/FeishuCLIProcessRunner.swift`
- `Sources/Core/Magician/CLI/FeishuCLIProvider.swift`
- `Sources/Core/Magician/CLI/FeishuOperationCatalog.swift`
- `Sources/Core/Magician/CLI/FeishuResultVerifier.swift`
- `Sources/Core/Magician/CLI/FeishuTargetResolver.swift`
- `Sources/Core/Magician/CLI/MagicianCLIRegistry.swift`
- `Sources/Core/Magician/MagicianAgentModels.swift`
- `Sources/Core/Magician/MagicianCapabilityProbe.swift`
- `Sources/Core/Magician/MagicianCommandSemantics.swift`
- `Sources/Core/Magician/MagicianFeatureModels.swift`
- `Sources/Core/Magician/MagicianFeatureToggleStore.swift`
- `Sources/Core/Magician/MagicianIntent.swift`
- `Sources/Core/Magician/MagicianMailAdapter.swift`
- `Sources/Core/Magician/MagicianMailSupport.swift`
- `Sources/Core/Magician/MagicianPermissionPromptModel.swift`
- `Sources/Core/Magician/MagicianPromptBuilders.swift`
- `Sources/Core/Magician/MagicianStatusResolver.swift`
- `Sources/Core/Magician/MagicianToolExecutor.swift`
- `Sources/Core/Magician/MagicianToolSupport.swift`
- `Sources/Core/Permissions/PermissionsCenter.swift`
- `Sources/Core/Rewrite/OpenAITextGenerationProvider.swift`
- `Sources/Core/Rewrite/RewriteProvider.swift`
- `Sources/Core/Security/CredentialStoreFactory.swift`
- `Sources/Core/Security/KeychainProviderCredentialStore.swift`
- `Sources/Core/Session/InputLane.swift`
- `Sources/Core/Session/SessionPhase.swift`
- `Sources/Core/Session/SessionStore.swift`
- `Sources/Core/Skills/SkillRuleStore.swift`
- `Sources/Core/Speech/ASRDictionaryStore.swift`
- `Sources/Core/Speech/DashScopeSupport.swift`
- `Sources/Core/Speech/LocalSenseVoiceProvider.swift`
- `Sources/Core/Speech/LocalSenseVoiceRuntimeManager.swift`
- `Sources/Core/Speech/OpenAIEndpointResolver.swift`
- `Sources/Core/Speech/OpenAITranscriptionProvider.swift`
- `Sources/Core/Speech/ProviderSettingsStore.swift`
- `Sources/Core/Speech/SpeechConnectionTesters.swift`
- `Sources/Core/Speech/SpeechProvider.swift`
- `Sources/Core/Speech/SpeechProviderRegistry.swift`
- `Sources/Core/Storage/LocalStore.swift`
- `Sources/Core/TextOutput/TextOutputCoordinator.swift`
- `Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift`
- `Sources/Core/V4/Adapters/V4ProviderSettingsBridge.swift`
- `Sources/Core/V4/Adapters/V4RuntimeSwitchStore.swift`
- `Sources/Core/V4/Adapters/V4SkillRuleBridge.swift`
- `Sources/Core/V4/Adapters/V4ToHistoryBridge.swift`
- `Sources/Core/V4/Adapters/V4ToSessionStoreBridge.swift`
- `Sources/Core/V4/AgentLoop/V4AgentContracts.swift`
- `Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift`
- `Sources/Core/V4/AgentLoop/V4PlannerLLM.swift`
- `Sources/Core/V4/AgentLoop/V4PlannerRuleBased.swift`
- `Sources/Core/V4/AgentLoop/V4PostStepDeciderDefault.swift`
- `Sources/Core/V4/AgentLoop/V4PostStepDeciderPlannerDriven.swift`
- `Sources/Core/V4/AgentLoop/V4VerifierDefault.swift`
- `Sources/Core/V4/Memory/V4MemoryBridge.swift`
- `Sources/Core/V4/Memory/V4MemoryContracts.swift`
- `Sources/Core/V4/Memory/V4MemoryEngine.swift`
- `Sources/Core/V4/Memory/V4MemoryEntry.swift`
- `Sources/Core/V4/Memory/V4MemoryIndex.swift`
- `Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift`
- `Sources/Core/V4/Model/V4ModelSlotContracts.swift`
- `Sources/Core/V4/Model/V4ModelSlotManager.swift`
- `Sources/Core/V4/Model/V4ModelSlots.swift`
- `Sources/Core/V4/Prompt/V4PromptContracts.swift`
- `Sources/Core/V4/Prompt/V4PromptLayerProviders.swift`
- `Sources/Core/V4/Prompt/V4PromptStackResolver.swift`
- `Sources/Core/V4/README.md`
- `Sources/Core/V4/Shared/V4Primitives.swift`
- `Sources/Core/V4/Shared/V4RuntimeModels.swift`
- `Sources/Core/V4/TimeMachine/V4ReminderScheduler.swift`
- `Sources/Core/V4/TimeMachine/V4TimeMachineContracts.swift`
- `Sources/Core/V4/TimeMachine/V4TimeMachineService.swift`
- `Sources/Core/V4/TimeMachine/V4TimeMachineStore.swift`
- `Sources/Core/V4/TimeMachine/V4TimeParser.swift`
- `Sources/Core/V4/TimeMachine/V4UserProfileDigest.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4AppleNotesTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4AppleScriptTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4CalendarCreateTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4FeishuCLITool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4MDPipelineTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4MailComposeTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4MusicControlTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4ShellCommandTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TextTransformTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TimeMachineCreateTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TimeMachineRemindTool.swift`
- `Sources/Core/V4/ToolKernel/V4EvidenceNormalizer.swift`
- `Sources/Core/V4/ToolKernel/V4PermissionGate.swift`
- `Sources/Core/V4/ToolKernel/V4ToolBatchOrchestrator.swift`
- `Sources/Core/V4/ToolKernel/V4ToolContracts.swift`
- `Sources/Core/V4/ToolKernel/V4ToolErrorCatalog.swift`
- `Sources/Core/V4/ToolKernel/V4ToolEvidencePolicy.swift`
- `Sources/Core/V4/ToolKernel/V4ToolHookPipeline.swift`
- `Sources/Core/V4/ToolKernel/V4ToolKernel.swift`
- `Sources/Core/V4/ToolKernel/V4ToolManifest.swift`
- `Sources/Core/V4/ToolKernel/V4ToolManifestIndex.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRetryPolicy.swift`

### 14.4 Sources/Resources
- `Sources/Resources/.DS_Store`
- `Sources/Resources/MagicianAgent/Agent.md`
- `Sources/Resources/MagicianSkills/README.md`
- `Sources/Resources/MagicianSkills/magician-skills.json`
- `Sources/Resources/diagnostic-voice-zh.wav`

### 14.5 Config
- `Config/AppRuntimePolicy.plist`
- `Config/Debug.xcconfig`
- `Config/LocalSecrets.xcconfig`
- `Config/Release.xcconfig`

### 14.6 Tests
- `Tests/ASRDictionaryStoreTests.swift`
- `Tests/AppRuntimePolicyTests.swift`
- `Tests/AppScenePolicyStoreTests.swift`
- `Tests/AudioCaptureServiceDurationTests.swift`
- `Tests/BrainstormDurationProbePlannerTests.swift`
- `Tests/BrainstormFallbackComposerTests.swift`
- `Tests/ControlCenterStateTests.swift`
- `Tests/CredentialStoreFactoryTests.swift`
- `Tests/DashScopeAndLocalASRTests.swift`
- `Tests/FeishuCLIProviderTests.swift`
- `Tests/FeishuResultVerifierTests.swift`
- `Tests/GlobalHotkeyStateMachineTests.swift`
- `Tests/HUDProgressStateMachineTests.swift`
- `Tests/HomeStatsFormatterTests.swift`
- `Tests/HotkeyStateStoreTests.swift`
- `Tests/InteractionCoordinatorTests.swift`
- `Tests/InteractionCoordinatorV4RoutingTests.swift`
- `Tests/KeychainProviderCredentialStoreTests.swift`
- `Tests/LocalHistoryStoreTests.swift`
- `Tests/LocalSenseVoiceRuntimeManagerTests.swift`
- `Tests/MagicianAgentRuntimeScenarioTests.swift`
- `Tests/MagicianCommandSanitizerTests.swift`
- `Tests/MagicianCommandSemanticsTests.swift`
- `Tests/MagicianFeatureToggleStoreTests.swift`
- `Tests/MagicianMailSupportTests.swift`
- `Tests/MagicianMusicQueryTests.swift`
- `Tests/MagicianSemanticLaneRouterTests.swift`
- `Tests/MagicianStatusResolverTests.swift`
- `Tests/MemoryEntryTextResolverTests.swift`
- `Tests/ModifierCaptureStateMachineTests.swift`
- `Tests/OpenAIEndpointResolverTests.swift`
- `Tests/OpenAIProviderAdapterTests.swift`
- `Tests/PermissionsCenterTests.swift`
- `Tests/ProviderSettingsStoreTests.swift`
- `Tests/RewriteIntentParserTests.swift`
- `Tests/SceneAppDiscoveryTests.swift`
- `Tests/SessionStoreTests.swift`
- `Tests/SkillRuleStoreTests.swift`
- `Tests/V4AgentLoopEngineTests.swift`
- `Tests/V4MDPipelineToolTests.swift`
- `Tests/V4MemoryEngineTests.swift`
- `Tests/V4ModelSlotManagerTests.swift`
- `Tests/V4PlannerLLMTests.swift`
- `Tests/V4PromptStackResolverTests.swift`
- `Tests/V4ReminderSchedulerTests.swift`
- `Tests/V4TimeMachineServiceTests.swift`
- `Tests/V4TimeParserTests.swift`
- `Tests/V4ToolEvidencePolicyTests.swift`
- `Tests/V4ToolExecutionScenarioTests.swift`
- `Tests/V4ToolKernelTests.swift`
- `Tests/V4ToolManifestTests.swift`

### 14.7 scripts
- `scripts/auto-ship.sh`
- `scripts/doctor-runtime.sh`
- `scripts/install-local-app.sh`
- `scripts/install-pre-commit-hook.sh`
- `scripts/lib/runtime-policy.sh`
- `scripts/repair-local-runtime.sh`
- `scripts/secret-scan.sh`
- `scripts/setup-local-keys.sh`
- `scripts/test-magician-fast.sh`
- `scripts/writeback_probe.swift`

### 14.8 docs
- `docs/.DS_Store`
- `docs/adr/0001-helper-app-direction.md`
- `docs/api-key-setup.md`
- `docs/architecture.md`
- `docs/audio-session.md`
- `docs/compatibility-matrix-v1.md`
- `docs/engineering-plan.md`
- `docs/engineering-playbook.md`
- `docs/hotkeys-permissions.md`
- `docs/install.md`
- `docs/local-history-and-scene-policy.md`
- `docs/magician-agent-research-20260330.md`
- `docs/milestones.md`
- `docs/product-principles.md`
- `docs/project-overview.md`
- `docs/pulsetype-99637ae-全项目功能与技术链路详解.md`
- `docs/release-checklist.md`
- `docs/text-output.md`
- `docs/transcription-provider.md`
- `docs/usage.md`
- `docs/v1-backlog.md`
- `docs/v4-handoff/v4-final-state.md`
- `docs/v4-handoff/window-01.md`
- `docs/v4-handoff/window-02.md`
- `docs/v4-handoff/window-03.md`
- `docs/v4-handoff/window-04.md`
- `docs/v4-handoff/window-05.md`
- `docs/v4-handoff/window-06.md`
- `docs/v4-handoff/window-07.md`
- `docs/v4-handoff/window-08.md`
- `docs/v4-handoff/window-09.md`
- `docs/v4-handoff/window-10.md`
- `docs/v4/architecture/claudecode-loop-tool-map.md`
- `docs/v4/architecture/product-module-map.md`
- `docs/v4/architecture/v4-delete-plan-windowed.md`
- `docs/v4/architecture/v4-master-architecture.md`
- `docs/v4/architecture/v4-risk-register.md`
- `docs/v4/architecture/v4-type-mapping.md`
