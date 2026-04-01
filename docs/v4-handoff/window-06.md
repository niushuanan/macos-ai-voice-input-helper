# Window 06 - V4 记忆索引与检索层

## 本窗目标

- 建立 V4 memory 的数据模型、索引和检索引擎。
- 把 `LocalHistoryStore` 的 `SessionHistoryEntry` 桥接成运行时可检索条目。
- 在 V4 planner 输入前注入 `memoryHints / relatedRecentRuns / conflictWarnings`。
- 保持记忆页继续走旧 UI 数据源，不改页面行为。

## 本窗落地文件

- `Sources/Core/V4/Memory/V4MemoryEntry.swift`
- `Sources/Core/V4/Memory/V4MemoryIndex.swift`
- `Sources/Core/V4/Memory/V4MemoryEngine.swift`
- `Sources/Core/V4/Memory/V4MemoryBridge.swift`
- `Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift`
- `Sources/Core/V4/Shared/V4RuntimeModels.swift`
- `Sources/Core/Interaction/InteractionCoordinator.swift`
- `Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift`
- `Sources/Core/V4/Adapters/V4ToHistoryBridge.swift`
- `Sources/App/AppModel.swift`
- `Tests/V4MemoryEngineTests.swift`

## 索引结构说明

- 索引条目结构：`V4MemoryEntry`
  - 核心字段：`id / timestamp / lane / moduleTags / inputText / outputText / instructionText / goalSummary / stepSummaries / evidenceSummary / appliedSkills`
  - 补充字段：`appName / bundleID / source / traceID / sessionID`
- 桥接方式：`V4MemoryBridge`
  - `SessionHistoryMode.dictation -> V4Lane.directDictation`
  - `SessionHistoryMode.selectionRewrite -> V4Lane.selectionRewrite`
  - `SessionHistoryMode.brainstorm -> V4Lane.brainstormDiscussion`
  - 同时覆盖 `magicianGoalSummary / magicianStepSummaries / magicianEvidenceSummary`
- 索引实现：`V4MemoryIndex`
  - 每条 entry 预计算 `tokensByField`
  - 字段维度：`input / output / instruction / goal / steps / evidence / tags`
  - 建倒排表：`token -> [entryIndex, field, occurrenceCount]`
  - 中文 token 采用汉字串 + 单字 + 2~4 字 n-gram；英文保留单词与 `bundleID` 片段

## 评分公式

统一算式：

```text
finalScore = (keywordScore + fieldScore + laneBonus + appBonus) * recencyDecay
```

其中：

- `keywordScore`
  - 每命中一个 token 记 `1`
  - 同一字段重复命中额外加 `0.25 * (occurrenceCount - 1)`
- `fieldScore`
  - `instruction = 6`
  - `goal = 5`
  - `output = 4`
  - `input = 3`
  - `steps = 2.5`
  - `tags = 2.5`
  - `evidence = 2`
- `laneBonus`
  - 当前 lane 与历史 lane 一致时 `+3`
- `appBonus`
  - 当前 `bundleID` 与历史 `bundleID` 一致时 `+2`
- `recencyDecay`
  - `0.35 + 0.65 * exp(-(ageHours / 168))`
  - 越近的历史越接近 `1.0`
  - 时间越远，分数会继续下降，但不会直接掉成 `0`

检索输出：

- 默认 `TopK = 5`
- 每条命中都返回：
  - `score`
  - `reasons`
  - 合并后的 `matchedSummary`

## planner 注入点

- 注入时机：`InteractionCoordinator.executeSelectionRewriteWithV4(...)`
- 顺序：
  1. 先构建基础 `V4RunRequest`
  2. 调 `V4MemoryQueryPlannerInputAdapter.adapt(...)`
  3. 把增强后的 request 传给 `V4MagicianRuntimeAdapter`
- 注入内容：
  - `memoryHints`
  - `relatedRecentRuns`
  - `conflictWarnings`
  - `memoryDebugTrace`
- 容错：
  - memory adapter 是非阻断式路径
  - 即便没有命中，也只会写空结果和 debug note，不会阻断主流程
- trace：
  - `V4ToHistoryBridge` 已把 memory 注入结果追加进 `magicianExecutionTrace`

## UI 与运行时的边界

- 记忆页不改：
  - 仍读 `LocalHistoryStore`
  - 仍走 `MemoryEntryTextResolver`
- V4 memory 只做运行时 retrieval：
  - 不替代页面数据源
  - 不改记忆页过滤器、复制逻辑和展示逻辑

## 已删旧注入路径

- 本窗没有删除旧的“临时拼接历史文本给模型”代码。
- 原因：
  - 当前 V4 主链里还没找到已在线上生效的历史拼接段
  - 旧 `V4MemoryContracts.swift` 虽然是旧草稿，但不在 Xcode target 内，本窗先不动它，避免把“未接线的草稿文件”误记成运行路径删除
- 下一窗如果要继续清理，应先复查：
  - `Sources/Core/Magician/MagicianAgentModels.swift`
  - `Sources/Core/Magician/MagicianPromptBuilders.swift`
  - `Sources/Core/V4/Prompt/`

## Window 07 需要先读的 prompt/model 文件

- `Sources/Core/V4/Prompt/V4PromptContracts.swift`
- `Sources/Core/V4/Model/V4ModelSlotContracts.swift`
- `Sources/Core/Speech/ProviderSettingsStore.swift`
- `Sources/Core/Magician/MagicianPromptBuilders.swift`

## 本窗新增测试

- `testIndexBuildFromHistoryEntries`
- `testKeywordSearchReturnsTopK`
- `testLaneMatchBoostsScore`
- `testRecencyDecayAffectsRanking`
- `testStableSortForEqualScore`
- `testPlannerInputAdapterIncludesMemoryHints`

## 本窗命令与结果

### 定向测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4MemoryEngineTests
```

结果：

- 6 tests, 0 failures
- `V4MemoryEngineTests` 全部通过

### fast suite

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
./scripts/test-magician-fast.sh
```

结果：

- `fast suite passed`

### 自动发布

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
scripts/auto-ship.sh --message "core: add v4 memory retrieval layer" --files PulseType.xcodeproj/project.pbxproj Sources/App/AppModel.swift Sources/Core/Interaction/InteractionCoordinator.swift Sources/Core/V4/Adapters/V4ToHistoryBridge.swift Sources/Core/V4/AgentLoop/V4AgentLoopEngine.swift Sources/Core/V4/Shared/V4RuntimeModels.swift Sources/Core/V4/Memory/V4MemoryBridge.swift Sources/Core/V4/Memory/V4MemoryEngine.swift Sources/Core/V4/Memory/V4MemoryEntry.swift Sources/Core/V4/Memory/V4MemoryIndex.swift Sources/Core/V4/Memory/V4MemoryQueryPlannerInputAdapter.swift Tests/V4MemoryEngineTests.swift docs/v4/architecture/product-module-map.md docs/v4-handoff/window-06.md
```

结果：

- 已完成 commit：`24d9fc3`
- 已 push 到：`origin/codex/magician-agent-v2`
- 已覆盖安装：`/Applications/PulseType.app`
- 脚本默认跳过 test phase；本窗测试已在脚本前单独跑完并通过
