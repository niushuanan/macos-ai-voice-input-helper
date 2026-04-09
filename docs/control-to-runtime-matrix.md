# PulseType Control-to-Runtime Matrix

更新时间：2026-04-09

分类说明：

- `真实写入`：UI 会改到 store / 本地持久化，运行时会读取。
- `真实 system action`：UI 会直接触发系统权限请求、打开系统设置或系统 App。
- `只读展示`：UI 只反映状态，不改数据。
- `需要修正`：当前文案或交互容易让人误会，已在本轮一并调整。

## Control Center

### 首页

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 首页 | 历史对话时长 / 输入字数 / 平均速度 / 节省时间 | `LocalHistoryStore.lifetimeSnapshot` | `ControlCenterState.homeStatsSnapshot` | `只读展示` |
| 首页 | 核心特点文案 | 静态文案 | 无 | `只读展示` |

### 记忆

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 记忆页 | 筛选栏 | `ControlCenterState.memoryFilter` | `filteredHistoryEntries` | `真实写入` |
| 记忆页 | 复制结果 / 原文 / 指令 / 执行链路 | `SessionHistoryEntry` | 剪贴板写入 | `真实 system action` |
| 记忆页 | 删除单条 | `LocalHistoryStore.delete` | 历史记录立刻变更 | `真实写入` |
| 记忆页 | 清空记录 / 深度清洗 | `LocalHistoryStore` / `V4TimeMachineStore` / diagnostics 目录 | 首页统计、时光机、历史轨迹同步变化 | `真实写入` |

### 词典

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 词典页 | 词典编辑框 | `ASRDictionaryStore.rawText` | 下一次 ASR 请求注入 | `真实写入` |
| 词典页 | 保存按钮 | `ASRDictionaryStore.save` | `InteractionCoordinator` 的 ASR 注入链路 | `真实写入` |
| 词典页 | 统计行数 / 有效词条 / 注入长度 | `ASRDictionaryStore.preview` | 无 | `只读展示` |

### 模型

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 模型页 | ASR provider / URL / model / key | `ProviderSettingsStore.asrConfig` | `SpeechProviderRegistry` / ASR test runtime / 实际转写流程 | `真实写入` |
| 模型页 | 文本处理 provider / URL / model / key | `ProviderSettingsStore.textConfig` | `RewriteProviderRegistry` / 文本处理流程 | `真实写入` |
| 模型页 | CLI provider / URL / model / key | `ProviderSettingsStore.cliTextConfig` | CLI Agent 文本模型链路 | `真实写入` |
| 模型页 | 测试按钮 | 运行时探测 | `runASRTest` / `runTextTest` / `runCLITextTest` | `真实 system action` |
| 模型页 | 最新测试状态 / 当前配置 | `ProviderSettingsStore.latest*TestResult` + config | HUD 之外仅展示 | `只读展示` |
| 模型页 | Local SenseVoice 准备环境 / 重新检测 | `LocalSenseVoiceRuntimeManager` | 本地 ASR 运行环境探测与准备 | `真实 system action` |

### 时光机

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 时光机页 | 概览统计 | `V4TimeMachineStore.loadItems` | 无 | `只读展示` |
| 时光机页 | 刷新时光机 | `V4TimeMachineStore.loadItems` | 列表立刻刷新 | `真实写入` |
| 时光机页 | 打开时钟 / 闹钟 / 计时器 | `NSWorkspace.open` | 系统 Clock / handoff | `真实 system action` |
| 时光机页 | 提醒状态 / Clock 入口状态 | 通知授权状态 + Clock capability | 无 | `只读展示` |

### 魔术先生

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 魔术先生页 | 功能总开关 | `MagicianFeatureToggleStore` | `V4PermissionGate` | `真实写入` |
| 魔术先生页 | 文本处理依赖状态 | 辅助功能权限 + 文本模型可用性 | `MagicianStatusResolver` | `只读展示` |
| 魔术先生页 | 日历依赖状态 | `EKEventStore.authorizationStatus` | `MagicianStatusResolver` | `只读展示` |
| 魔术先生页 | 邮件 / 音乐 / Clock 依赖状态 | Mail / Music / Clock capability probe | `MagicianStatusResolver` | `只读展示` |
| 魔术先生页 | 行内动作按钮 | `MagicianPermissionPromptModel.primaryAction` | 请求权限 / 打开系统设置 / 打开 Mail / Music / Clock / 切到模型页 | `真实 system action` |
| 魔术先生页 | 第三页旧“全算权限”文案 | 旧 UI 误导 | 本轮已改成权限 / 模型 / 依赖三类状态 | `需要修正` |

### 一口气全念对

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 一口气全念对页 | 双击修饰键录入 | `HotkeyStateStore.brainstormModifier` | `GlobalHotkeyService` | `真实写入` |
| 一口气全念对页 | 当前模型上限 / 推荐时长 | `BrainstormDurationProfileStore` | 无 | `只读展示` |
| 一口气全念对页 | 冲突提示 | `HotkeyStateStore.conflictMessage` | 无 | `只读展示` |

### 设置

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| 设置页 | 口语过滤 | `SkillRuleStore.spokenFilter` | `V4PromptLayerProviders.nowYouSeeMe` | `真实写入` |
| 设置页 | 个性提示词 | `SkillRuleStore.systemPrompt` | `V4PromptLayerProviders.nowYouSeeMe` | `真实写入` |
| 设置页 | 按应用风格总开关 | `SkillRuleStore.appPreferenceBoost` | `V4PromptLayerProviders.appScene` / `InteractionCoordinator` | `真实写入` |
| 设置页 | 应用搜索 / 添加 / 编辑提示词 | `AppScenePolicyStore` | `V4PromptLayerProviders.appScene` / `InteractionCoordinator` | `真实写入` |
| 设置页 | 主键 / 脑暴修饰键 | `HotkeyStateStore` | `GlobalHotkeyService` | `真实写入` |
| 设置页 | 权限中心请求按钮 | `PermissionsCenter.requestAccess` | 麦克风 / 辅助功能真实权限请求 | `真实 system action` |
| 设置页 | 打开系统设置 | `PermissionsCenter.openSystemSettings` | 系统设置对应 Privacy 页 | `真实 system action` |
| 设置页 | 权限状态 / 安装路径诊断 | `PermissionsCenter.snapshot` / `runtimeDiagnostics` | 无 | `只读展示` |

## Menu Bar

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| Menu Bar 状态图标 | phase 图标、监听电平、busy dots | `SessionStore.phase` / `listeningLevel` | `MenuBarStatusView` | `只读展示` |
| Menu Bar 菜单 | 阶段 / 通道 / provider / 快捷键文本 | `SessionStore` / `ProviderSettingsStore` / `HotkeyStateStore` | `MenuBarMenuView` | `只读展示` |
| Menu Bar 菜单 | 开始听写 / 开始一口气全念对 / 取消会话 | `InteractionCoordinator` | 真实会话切换 | `真实 system action` |
| Menu Bar 菜单 | 打开隐私设置 | `PermissionsCenter.openSystemSettings` | 系统设置 | `真实 system action` |
| Menu Bar 菜单 | 打开主界面 / 退出 | `openWindow` / `NSApplication.terminate` | 主窗 / app 生命周期 | `真实 system action` |

## HUD

| UI 位置 | 控件 / 信息 | source of truth | 下游 consumer / action | 当前结论 |
| --- | --- | --- | --- | --- |
| HUD | phase / lane / message / progressHint / listeningLevel | `SessionStore` | `AppModel.bindStatusPulse -> StatusPulseHUDController.show` | `只读展示` |
| HUD | 完成 / 失败 / 取消文案 | `StatusPulseHUDMessageResolver` | 与 `SessionStore.statusMessage` 对齐 | `只读展示` |
| HUD | 浮层展示与消失 | `StatusPulseHUDController` state machine | `NSPanel` 非激活浮层 | `真实 system action` |

## 本轮重点修正

1. `魔术先生` 页面不再把 `系统权限 / 模型依赖 / 系统 App 依赖` 混成一种状态文案。
2. `设置 / 模型 / 魔术先生` 改成 grouped rows，避免多层卡片造成“看起来像摆设”的感觉。
3. `模型` 页测试按钮与状态区改成同一组信息层级，避免“按钮很大但反馈很轻”的视觉失真。
