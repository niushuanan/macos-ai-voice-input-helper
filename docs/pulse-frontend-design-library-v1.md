# PulseType Frontend Design Library v1

适用范围：macOS 主窗口、设置页、菜单栏、HUD、弹层、表单卡片。  
目标：简洁、冷静、可读、低打扰，同时保留高级质感。

## 1. Typography Scale（8 档）

| Token | Size | Line Height | Weight | 使用场景 |
|---|---:|---:|---|---|
| `hero` | 24 | 30 | Bold | 页面主标题，仅页头使用 |
| `section` | 15.5 | 20 | Semibold | 卡片标题、区块标题 |
| `body-medium` | 13.5 | 18 | Medium | 关键正文、核心状态文案 |
| `body` | 13.5 | 18 | Regular | 常规正文 |
| `caption-strong` | 12 | 16 | Semibold | 标签、短状态字 |
| `caption` | 12 | 16 | Regular | 辅助说明 |
| `tiny` | 11 | 14 | Regular | 元信息、路径、诊断值 |
| `metric` | 19 | 24 | Semibold | 首页数据值 |

规则：
- 页面最多 4 层文字等级并行出现。
- 同一块内容，主文案与副文案字号差不超过 3.5pt。
- 长段正文统一 `lineSpacing` 1.4 到 1.8。

## 2. Spacing System（4pt 基线）

| Token | Value | 场景 |
|---|---:|---|
| `space-2` | 8 | 图标与字、标签间距 |
| `space-3` | 12 | 卡片内默认间距 |
| `space-4` | 16 | 区块内分组 |
| `space-5` | 20 | 页面纵向主节奏 |
| `page-horizontal` | 22 | 页面左右边距 |
| `page-vertical` | 20 | 页面上下边距 |

## 3. Radius System

| Token | Value | 场景 |
|---|---:|---|
| `radius-header` | 16 | 页头容器 |
| `radius-group` | 14 | 主卡片 |
| `radius-card` | 11 | 一般卡片 |
| `radius-compact` | 9 | 内嵌面板、状态块 |
| `radius-pill` | 999 | pill / capsule |

## 4. Color Roles

| Role | 用途 |
|---|---|
| `textPrimary` | 主内容文字 |
| `textSecondary` | 次级说明 |
| `textTertiary` | 弱提示 |
| `accent` | 单一强调色（交互焦点） |
| `success` | 成功 |
| `warning` | 注意 |
| `danger` | 失败 / 异常 |

规则：
- 全局只保留 1 个强调色 + 3 个语义色。
- 状态表达必须“颜色 + 文案/图标”同时存在。

## 5. Elevation & Material

| Token | Value |
|---|---|
| `stroke` | 1px 低对比描边 |
| `shadow-soft` | 低透明度阴影，半径 8 到 12 |
| `material` | 优先系统 Material / glass |

规则：
- 阴影最多 1 层。
- 大面积正文区不铺重材质。

## 6. Motion

| 场景 | 时长 |
|---|---|
| 微交互 | 120 到 180ms |
| 卡片与面板切换 | 180 到 240ms |
| 页面级过渡 | 220 到 320ms |

规则：
- 一个动作只配一个主要动效。
- 禁止无业务意义的持续动效。

## 7. Component Rules

### Page Header
- 主标题 `hero`。
- 副标题 `body`，行距 1.8。
- 强调线宽度建议 160 到 180。

### Card
- 标题 `section`。
- 正文 `body`。
- 副说明 `caption`。
- 内边距 9 到 12。

### Form
- 字段标题 `caption-strong`。
- 输入内容 `body`。
- 技术选项默认折叠到“开发者选项”。

### Status Pill
- `caption-strong` + 语义色背景淡化。
- 仅表达单一状态，不承载长句。

### Menu Bar
- 默认只放阶段状态与高频动作。
- 技术诊断放到二级菜单。

### HUD
- 文案优先 10 到 11.5。
- 强调即时状态，不展示冗长描述。

## 8. 文案规范

- 普通用户路径：动词开头，短句，避免技术词。
- 技术信息路径：集中到“开发者入口（可选）”。
- 失败提示：先讲结果，再给一步操作建议。

## 9. 反模式

- 大字与小字跨度过大。
- 一个页面出现过多字号档位。
- 技术参数默认直出。
- 高饱和颜色大面积铺底。
- 重阴影和重边框叠加。
- 全屏都在动画。
