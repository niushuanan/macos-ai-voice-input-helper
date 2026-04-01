# V4 风险登记册

| 风险 ID | 触发条件 | 影响模块 | 临时规避方案 | 长期方案 |
| --- | --- | --- | --- | --- |
| R01 | V4 lane classifier 与当前 `MagicianLaneClassifier.decide(...)` 行为不一致 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | Window 02 先做双跑比对日志，不立刻切默认路径 | 把 lane 分类单独提成 `V4LaneRouter`，补全对照测试集 |
| R02 | `asrConfig`、`textConfig`、`cliTextConfig` 在 V4 里被误配到错误步骤 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ProviderSettingsStore.swift` | 初期强制 lane -> slot 映射写死，并在日志里打印 resolved slot | 新建 `V4ModelSlotResolver`，把 turn 级、tool 级、fallback 级规则写成可测逻辑 |
| R03 | `LocalHistoryStore` 里历史项太粗，memory retrieval 只能拉到脏上下文 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift` | 第一版只检索最近 N 条且按 lane 过滤 | 引入 `V4MemoryIndex`，按 lane、feature、app、time、status 建索引 |
| R04 | 词典提示过长，与 scene prompt、system prompt 叠加后让 prompt 失真 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ASRDictionaryStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift` | 先沿用现有 `didTruncate` 规则，并把字典层排在 prompt 尾部 | 在 `V4PromptComposer` 里做 token-aware 层级裁剪 |
| R05 | 当前工具权限逻辑散落在 OS capability probe、PermissionsCenter、Adapter 内，V4 一次性替掉容易漏判 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Permissions/PermissionsCenter.swift` | V4 初期保留旧 capability probe，先做统一包装，不直接删旧判断 | 建 `V4ToolPermission`，每个工具独立声明 require 条件与失败消息 |
| R06 | 长按主键时选中文本抓取与录音启动存在竞态，V4 若改入口桥可能丢 selection | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/TextOutput/TextOutputCoordinator.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` | 保留现有 `prepareMagicianSelectionCapture()` 方案直到 V4 bridge 稳定 | 把 selection capture 升成 V4 输入阶段的标准步骤，并记时间戳与来源 |
| R07 | `Feishu CLI` 的 canonical operation 与实际 CLI 参数漂移 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Tests/FeishuCLIProviderTests.swift` | 沿用现有 fast test 作为先导门禁 | 在 ToolKernel 里给 `Feishu CLI` 单独维护 schema 与 golden tests |
| R08 | 旧历史 schema 与时光机 checkpoint schema 不统一，导致 replay 拼不起来 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | 第一版时光机只读，不写回旧 schema | 引入 `V4Checkpoint` 与迁移器，把 history / checkpoint 统一成 timeline event |
| R09 | 一口气全念对的时长 profile 没迁好，ASR 太早停或太晚停 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/BrainstormDurationProfileStore.swift` | V4 切换初期继续读旧 profile 文件 | 最终把 profile 纳入 `V4Model/*` 或 `V4TimeMachine/*` 的统一元数据层 |
| R10 | 新旧 runtime 同时活着，排障时无法判断结果到底来自哪条链 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | 每个历史项、trace、HUD 文案都打印 `runtime=v3/v4` | V4 上线后尽快删旧分派点，不保留长期双跑 |
| R11 | Prompt Layer 还没集中，继续在 `SkillRuleStore`、Coordinator、Runtime 三处拼 prompt | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | Window 02 起禁止新增旧 prompt 拼接点 | Window 04 前落地 `V4PromptComposer`，所有新 prompt 只能走这一个入口 |
| R12 | 时光机当前没有 UI 与 API，团队容易把它拖成“以后再说” | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/TimeMachine/*`（目标目录） | 第一版先只做内核目录、schema、history bridge，不等 UI | 在 Window 05 前给时光机至少落一个 `timeline query` 与一个 handoff 展示入口 |
| R13 | `SessionStore` 若继续夹带业务判断，V4 AgentLoop 仍会被 UI 状态层反向绑住 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Session/SessionStore.swift` | 明确 `SessionStore` 只保留 phase/status/hud，不加业务字段 | 用 `V4LoopEvent` 驱动 `SessionStore`，禁止业务层直接改 UI 状态 |
| R14 | 本地已有未提交改动，自动发布时若文件列表不严，容易把无关变更带进 commit | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/.git` 工作区 | 只把本窗新增文件传给 `scripts/auto-ship.sh --files` | 后续若持续多人并行，给 auto-ship 增加 staged-file 校验与 dirty-file 报表 |

## 当前最该盯的 Top 5

1. R01：lane 分类不一致
2. R05：工具权限漏判
3. R08：历史与 checkpoint schema 不统一
4. R10：新旧 runtime 双跑太久
5. R11：Prompt Layer 继续分散
