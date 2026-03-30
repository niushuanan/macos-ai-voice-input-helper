# 工程开发手册（PulseType）

## 1. 目标

这份手册用于固定团队协作规则，降低“功能能跑但链路不稳、模块职责不清、改动互相打架”的问题。

适用范围：本仓库全部 Swift 代码、测试、脚本与文档改动。

## 2. 分层与依赖边界

### 2.1 依赖方向

允许方向：

- `UI -> App -> Core`
- `Core/Interaction -> Core/*`
- `Core/Magician -> Core/Magician/* + Core/Rewrite + Core/TextOutput + Core/Speech + Core/Skills`

禁止方向：

- `Core` 反向依赖 `UI`
- `SessionStore` 直接依赖具体 provider 或 CLI 实现
- `TextOutput` 依赖业务语义（如“日程”“音乐”）

### 2.2 模块职责红线

- `InteractionCoordinator` 只做编排，不做底层 I/O 细节。
- `MagicianToolExecutor` 只做动作执行与证据生成，不做 UI 状态管理。
- `TextOutputCoordinator` 只管写回路径，不做命令理解。
- `ProviderSettingsStore` 只管配置与 key 读取，不做业务流程判断。

## 3. 新代码落点规则

### 3.1 功能改动

- 普通语音输入链路：优先改 `Sources/Core/Interaction`、`Sources/Core/TextOutput`。
- Agent 计划/循环/校验：优先改 `Sources/Core/Magician/MagicianAgentModels.swift`。
- 外部动作（Apple/Feishu）：优先改 `Sources/Core/Magician/MagicianToolExecutor.swift` 与 `Sources/Core/Magician/CLI/*`。
- 模型调用与 prompt：优先改 `Sources/Core/Rewrite`、`Sources/Core/Speech`。

### 3.2 测试改动

- 编排回归：`Tests/InteractionCoordinatorTests.swift`
- Agent 场景回放：`Tests/MagicianAgentRuntimeScenarioTests.swift`
- 写回路径：`Tests/SessionStoreTests.swift`（`TextOutputCoordinatorTests`）
- Feishu 链路：`Tests/FeishuCLIProviderTests.swift`、`Tests/FeishuResultVerifierTests.swift`

## 4. 魔术先生专项规则

### 4.1 真 Agent 规则

- 必须走 `plan -> step invoke -> verify -> decide` 循环。
- 每一步都要产出证据文本，证据不足时必须判失败。
- 仅保留会话态，不做长期记忆。

### 4.2 伪成功防线

- 音乐 `play_query`：没有 `track=` 证据，一律失败。
- 飞书写动作：没有结构化结果字段，一律失败。
- 文案显示“成功”前，必须先过 verify。

### 4.3 技术实现约束

- `skillID` 在 runtime 内必须保持原始 skill（如 `apple.music.play_query`），不能在中途降成泛化 ID。
- verify 逻辑不能只看 `status=verified`，还要看证据内容是否匹配动作目标。

## 5. 文本写回规则

- 主路径：AX 直写。
- 兜底路径：定向粘贴（Command+V）。
- 最后兜底：仅剪贴板。

执行要求：

- 有可达目标时，不能直接退化到“仅剪贴板”。
- 若最终只能剪贴板，UI 与日志必须明确告知“未写入编辑区”。

## 6. 代码变更门禁

每次代码任务完成后，默认执行：

1. `xcodebuild test`
2. 仅提交本次改动文件
3. push 当前分支
4. 覆盖安装 `/Applications/PulseType.app`

统一脚本：

```bash
scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...]
```

## 7. 文档同步规则

以下变动必须同步文档：

- 新增/删除模块
- 改动主链路阶段
- 改动发布或测试门禁
- 改动外部能力判定规则（如音乐/飞书校验）

推荐同步位置：

- `docs/project-overview.md`
- `docs/architecture.md`
- `docs/release-checklist.md`

## 8. 当前已知技术债

- `MagicianAgentModels.swift` 文件体量偏大，建议继续拆分。
- `InteractionCoordinator` 编排逻辑较密，建议按 lane 拆 extension。
- 真机端到端自动回测还不够，尤其是“App 未打开时拉起 + 动作执行”场景。

## 9. PR / Commit 最低标准

- 改动说明必须写清：改了什么、为何改、如何验真。
- 至少一条自动化测试覆盖本次风险点。
- 不把无关文件带入同一提交。
- 日志与错误提示保持可读，不要出现“执行失败”这类空泛提示。
