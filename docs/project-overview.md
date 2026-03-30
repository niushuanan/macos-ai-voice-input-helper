# 项目概览（PulseType 2.1）

## 1. 产品定位

PulseType 是一款 macOS 常驻语音助手，目标是“说一句，办一件事”。

当前主能力有三条：

- 普通语音输入：把语音转写后写入当前编辑区。
- 魔术先生 Agent：按步骤调用 skill，完成改写、系统动作、CLI 动作。
- 一口气全念对：把口述内容整理为结构化上下文，再写入编辑区。

## 2. 代码版图（事实）

### 2.1 顶层目录

- `Sources/App`：App 入口、依赖装配、生命周期。
- `Sources/Core`：业务核心。
- `Sources/UI`：SwiftUI 控制台页面与组件。
- `Sources/Resources`：skill 清单、资源文件。
- `Tests`：单测与场景回放。
- `scripts`：测试、发布、安装、诊断脚本。
- `docs`：产品与工程文档。

### 2.2 Core 子模块职责

- `Session`：会话状态机、进度与阶段流转。
- `Interaction`：主编排器，串起录音、ASR、后处理、写回、Agent 运行。
- `Speech`：ASR provider 抽象、配置、请求与回包解析。
- `Rewrite`：文本模型调用与改写流程。
- `TextOutput`：AX 直写、粘贴兜底、剪贴板路径。
- `Magician`：Agent 模型、skill runtime、Apple/Feishu 执行器。
- `Context`：前台 App 与编辑态探测。
- `History`：本地历史记录。
- `Diagnostics`：链路日志与诊断信息。
- `Hotkey` / `Permissions` / `Security` / `Storage` / `Skills`：快捷键、权限、凭据、本地存储、规则。

### 2.3 运行主链路

- App 入口：`Sources/App/PulseTypeApp.swift`
- 依赖装配：`Sources/App/AppModel.swift`
- 主编排：`Sources/Core/Interaction/InteractionCoordinator.swift`
- 会话状态：`Sources/Core/Session/SessionStore.swift`
- Agent 内核：`Sources/Core/Magician/MagicianAgentModels.swift`
- 外部动作执行：`Sources/Core/Magician/MagicianToolExecutor.swift`
- 文本写回：`Sources/Core/TextOutput/TextOutputCoordinator.swift`

## 3. 工程现状判断（推断）

- 代码已经从“规则分支机”转向“Agent 循环”，核心方向正确。
- `InteractionCoordinator` 职责偏重，是当前复杂度最高点。
- `MagicianAgentModels.swift` 体量偏大，后续继续拆分会更稳。
- 测试覆盖面不错，尤其是 `InteractionCoordinatorTests`、`MagicianAgentRuntimeScenarioTests`。

## 4. 主要风险（事实 + 推断）

- 写回链路依赖 AX 与目标 App 行为差异，跨 App 稳定性仍有波动。
- 音乐、飞书等外部动作若证据规则不严，容易出现“界面显示成功但实际未完成”。
- Agent 内核与 tool runtime 代码密集在少量大文件里，协作改动时冲突概率较高。

## 5. 下一步优先项

- 继续拆分 `MagicianAgentModels.swift`：按 `plan/runtime/tools/verify` 拆文件。
- 给写回链路补更多真实场景测试：目标 App 未激活、焦点漂移、权限切换。
- 给魔术先生 UI 增加“步骤证据可视化一致性校验”，防止伪成功文案。

## 6. 待确认问题

- 冷启动场景下，Music 指令成功率基线数据还缺统一统计。
- 飞书写动作在弱网和 token 过期时的自动恢复策略还未统一。
- 长会话中 Agent token 预算阈值与时延目标，需要再做一轮压测定标。
