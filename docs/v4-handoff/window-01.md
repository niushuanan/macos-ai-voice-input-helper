# Window 01 Handoff

## 本窗完成项
- 完成 `claudecode` 主循环与工具层阅读，确认 V4 应对齐 `query.ts` 与 `services/tools/*` 的 `AgentLoop + ToolKernel` 结构。
- 完成 PulseType 当前模块盘点，明确 8 个固定模块的当前文件、数据结构、入口函数、测试文件。
- 新建 `docs/v4/architecture` 与 `docs/v4-handoff`。
- 落地 5 份架构文档与 1 份 V4 目录入口文档。
- 执行 `./scripts/test-magician-fast.sh`，当前基线通过。

## 本窗新增文件
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/product-module-map.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/claudecode-loop-tool-map.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/v4-master-architecture.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/v4-delete-plan-windowed.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/v4-risk-register.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/README.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4-handoff/window-01.md`

## 已确认可删的旧逻辑
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 里的 `selectedRuntime` 分派与旧 `outputSelectionRewrite(...)` 支线，等 V4 lane bridge 跑通即可移走。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 里的 `MagicianLaneClassifier`、`MagicianNativeRuntime`、`MagicianAgentRuntimeV3` 主循环，等 V4 `AgentLoop` 与 `ToolKernel` 上线后逐窗移走。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` 这个巨石工具层，等 ToolKernel adapters 拆完后整文件移走。

## 暂时保留的旧逻辑与原因
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ProviderSettingsStore.swift`
  原因：三槽位配置已经稳定，V4 先把它当配置源。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift`
  原因：rule 配置与 `systemPrompt` 仍要给 V4 Prompt Layer 使用。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ASRDictionaryStore.swift`
  原因：词典仍是 ASR 与 Prompt Layer 的输入源。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift`
  原因：V4 `memory retrieval` 与时光机第一版都要借它起步。
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Session/SessionStore.swift`
  原因：UI 状态壳先保留，后续改成只吃 `V4LoopEvent`。

## 当前风险 Top 5
- lane 分类迁移后与旧 `MagicianLaneClassifier.decide(...)` 不一致。
- 工具权限判断从散点逻辑改成统一 ToolKernel 时漏判。
- 历史记录与 checkpoint schema 还没统一，时光机可能拼不出完整 timeline。
- 新旧 runtime 若双跑过久，排障与历史 trace 会变得混乱。
- Prompt 组装若不尽快集中，旧文件还会继续长出新分支。

## Window 02 第一条动作
- 先建 `Sources/Core/V4/AgentLoop/` 的骨架文件，把 `InteractionCoordinator.handleWakeInput(context:)` 后的 lane 分派桥到 V4，先不删旧逻辑，只做桥接与双跑日志。

## Window 02 必读文件
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/v4-master-architecture.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/docs/v4/architecture/claudecode-loop-tool-map.md`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift`
- `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift`
- `/Users/zhuanghongkai/Desktop/src/query.ts`
- `/Users/zhuanghongkai/Desktop/src/services/tools/toolExecution.ts`
- `/Users/zhuanghongkai/Desktop/src/services/tools/toolOrchestration.ts`
- `/Users/zhuanghongkai/Desktop/src/services/tools/toolHooks.ts`

## 本窗命令与结果
- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && ./scripts/test-magician-fast.sh`
- 结果：通过。`xcodebuild` 退出码为 0，脚本输出 `[test] fast suite passed`。
- 命令：`cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法" && scripts/auto-ship.sh --message "docs: add v4 window 01 architecture blueprint" --files docs/v4/architecture/product-module-map.md docs/v4/architecture/claudecode-loop-tool-map.md docs/v4/architecture/v4-master-architecture.md docs/v4/architecture/v4-delete-plan-windowed.md docs/v4/architecture/v4-risk-register.md docs/v4-handoff/window-01.md Sources/Core/V4/README.md --with-test`
- 结果：通过。`commit=73aa53c`，`branch=codex/magician-agent-v2`，`push=origin/codex/magician-agent-v2`，`install=/Applications/PulseType.app`。
