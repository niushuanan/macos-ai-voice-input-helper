# Window 10 - V4 默认化 + legacy 最终瘦身

## 本窗目标

- 让魔术先生默认只走 V4 主链
- 把 legacy runtime 改成 debug 显式兜底
- 清掉还能直接删的旧命名 / 冗余接口
- 跑完全量验证并完成发布准备

## 本窗落地文件

- `Sources/Core/Interaction/InteractionCoordinator.swift`
- `Sources/Core/V4/Adapters/V4RuntimeSwitchStore.swift`
- `Sources/Core/Magician/MagicianToolExecutor.swift`
- `Sources/Core/Magician/MagicianMailAdapter.swift`
- `Tests/InteractionCoordinatorV4RoutingTests.swift`
- `README.md`
- `docs/v4/architecture/v4-master-architecture.md`
- `docs/v4-handoff/window-10.md`
- `docs/v4-handoff/v4-final-state.md`

## 最终切换结果

### 1. 默认链路

- `InteractionCoordinator` 默认只走 `V4MagicianRuntimeAdapter`
- legacy route 仍保留，但只有 `V4RuntimeSwitchStore` 显式打开 debug 开关时才允许进入
- 本窗进一步把 legacy stack 改成懒初始化：
  - 默认启动不再提前创建 `MagicianNativeRuntime`
  - 默认启动不再提前创建 `MagicianAgentRuntimeV3`
  - 默认启动不再提前创建 `MagicianToolExecutor`

### 2. 可删旧逻辑

本窗没有删除整文件，因为目前没有发现“无引用且不影响 debug / V4 共用 helper”的 legacy 文件。

本窗已删除的旧代码项：

- `InteractionCoordinator.outputSelectionRewriteV2`
- `MagicianToolExecutor.swift` 里未再使用的 `MagicianMailExecuting`
- `MagicianToolExecutor.init(...)` 里未再使用的 `mailAdapter` 参数

### 3. 历史与轨迹

以下字段继续稳定写盘：

- `magicianRuntimeVersion`
- `magicianSessionID`
- `magicianRunID`
- `magicianGoalSummary`
- `magicianStepSummaries`
- `magicianEvidenceSummary`
- `magicianExecutionTrace`

### 4. 兼容边界

- UI 分区未改
- 快捷键行为未改
- 用户已有能力语义未改

## 文档更新

- `README.md`
  - 增加 V4 默认主链说明
  - 增加时光机能力说明
- `docs/v4/architecture/v4-master-architecture.md`
  - 标注 Window 10 后 V4 已默认启用
  - 标注 legacy 仅做 debug 显式兜底，且默认不主动初始化
- 新建：
  - `docs/v4-handoff/window-10.md`
  - `docs/v4-handoff/v4-final-state.md`

## 验证结果

### 定向验证

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/InteractionCoordinatorV4RoutingTests -only-testing:PulseTypeTests/MagicianMailSupportTests -only-testing:PulseTypeTests/MagicianAgentRuntimeScenarioTests
```

结果：

- 27 tests, 0 failures
- 新增的 `testPreflightFailureStillRecordsV4WhenLegacyDebugEnabled` 通过

### 全量验证

```bash
./scripts/test-magician-fast.sh --full
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" build
./scripts/doctor-runtime.sh
```

结果：

- `./scripts/test-magician-fast.sh --full`
  - 第一次失败：`PulseType encountered an error (The test runner hung before establishing connection.)`
  - 失败点：系统里已有 `/Applications/PulseType.app` 常驻实例，test runner 建连卡住
  - 修复动作：先执行 `pkill -f '/Applications/PulseType.app/Contents/MacOS/PulseType'`
  - 第二次重跑通过：363 tests, 0 failures
- `xcodebuild ... build`
  - `BUILD SUCCEEDED`
- `./scripts/doctor-runtime.sh`
  - 诊断结束
  - `/Applications/PulseType.app` 存在
  - Spotlight 同时记录了安装版与 DerivedData 调试版
  - 当前进程权限显示：`microphone: notDetermined`、`accessibilityTrusted: true`

## Window 11 第一条动作

- 把 legacy debug runtime 继续下沉成更薄的 debug-only 装配层，避免 `InteractionCoordinator` 继续持有 legacy 构造细节
