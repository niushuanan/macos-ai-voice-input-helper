---
name: pulsetype-auto-ship
description: PulseType 项目专用自动发布流程。用于本仓库代码任务完成后自动执行严格门禁发布：先跑 xcodebuild test，再按指定文件 commit，随后 push 到当前分支，最后覆盖安装 /Applications/PulseType.app。若用户明确要求不要发布，则跳过发布链路。
---

# PulseType Auto Ship

## 执行目标

让本仓库在“代码任务完成”后走固定流程：`test -> commit -> push -> install`。

## 触发条件

- 任务包含代码或配置改动，并且用户没有明确说“不要发布”。
- 仓库存在 `origin` remote，且当前分支可推送。

## 统一流程

1. 明确本轮需提交文件列表与 commit message。
2. 执行：

```bash
scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...]
```

3. 如用户要求仅推送不覆盖安装：

```bash
scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...] --skip-install
```

## 门禁规则

- `xcodebuild test` 失败时必须停止，不可继续 push/install。
- push 失败时自动重试（脚本内最多 8 次）；达到上限后报错并停止。
- 仅提交显式传入文件，避免带入无关目录。

## 输出要求

发布流程执行后，必须报告：

- commit SHA
- branch
- push 状态
- install 状态
- 若某步跳过，说明原因
