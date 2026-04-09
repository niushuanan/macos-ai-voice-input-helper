# PulseType Frontend Design Library v2

适用范围：macOS 主窗口、设置页、菜单栏、HUD、弹层、表单卡片。  
设计方向：以 Anthropic 的冷静高级感为主轴，融合 macOS 原生交互一致性；保留品牌名称“时光机 / 魔术先生”。

## 1. 设计原则

1. 先结构，后视觉：先保证信息层级和操作路径，再做视觉装饰。  
2. 中性色主导：页面 90% 使用中性色，强调色只做关键反馈。  
3. 字号跨度克制：避免同屏“大字很大、小字很小”的断层。  
4. 语义优先：状态必须“颜色 + 文案/图标”双通道表达。  
5. 技术项隐藏：默认界面只放普通用户需要的信息，开发者项放折叠区。

## 2. Typography Tokens

| Token | Size | Line Height | Weight | 场景 |
|---|---:|---:|---|---|
| `pageTitle` | 21 | 27 | Semibold | 页头标题（可 Serif） |
| `sectionTitle` | 15 | 20 | Semibold | 区块标题 |
| `bodyStrong` | 13.5 | 19 | Medium | 关键正文 |
| `body` | 13.5 | 19 | Regular | 常规正文 |
| `captionStrong` | 12 | 17 | Semibold | 标签、短状态 |
| `caption` | 12 | 17 | Regular | 辅助说明 |
| `monospacedMeta` | 11 | 15 | Regular | 路径、ID、诊断信息 |
| `value` | 17 | 22 | Semibold | 数值型重点信息 |

规则：
- 同一屏最多并行 4 档字号。
- 标题到正文比例控制在 `1.4x` 左右，不再使用极大跃迁。
- 长段文字必须设 `lineSpacing`，正文用 `bodyLineSpacing`。

## 3. Spacing Tokens

| Token | Value | 场景 |
|---|---:|---|
| `pageHorizontal` | 24 | 页面左右边距 |
| `pageVertical` | 20 | 页面上下边距 |
| `section` | 16 | 区块容器内边距 |
| `cardPadding` | 14 | 卡片内边距 |
| `compactCardPadding` | 10 | 紧凑内嵌面板 |

规则：
- 统一 4pt 基线递进，避免随手写 7/13/19 这类随机间距。

## 4. Radius Tokens

| Token | Value | 场景 |
|---|---:|---|
| `header` | 14 | 页头 / 提示浮层 |
| `sectionGroup` | 12 | 一级分组卡片 |
| `card` | 10 | 普通卡片 |
| `compactCard` | 8 | 行内小面板 / 标签底 |
| `pill` | 999 | 胶囊 |

规则：
- 整体只保留 4 档有效圆角，避免页面像“圆角拼盘”。

## 5. Color Tokens

| Role | Value（语义） |
|---|---|
| `backgroundTop` | 暖灰浅底 |
| `backgroundBottom` | 暖灰中底 |
| `primaryFill` | 浅暖白卡片底 |
| `secondaryFill` | 次级卡片底 |
| `textPrimary` | 主文本 |
| `textSecondary` | 次文本 |
| `textTertiary` | 弱提示 |
| `glow` | 品牌强调（小面积） |
| `success` | 成功语义 |
| `warning` | 警示语义 |
| `danger` | 错误语义 |
| `stroke` | 低对比分隔线 |

规则：
- 禁止大面积高饱和纯色。
- 强调色只用于 CTA、激活状态、少量焦点引导。

## 6. Material & Elevation

1. 支持 glass 的系统版本：优先 `glassEffect(.regular)`，但仅用于容器层。  
2. 开启 `Reduce transparency`：自动降级为实色背景。  
3. `shadow` 保持浅层：卡片阴影半径约 `6~10`。  
4. 高对比模式：边线加深，不依赖阴影制造层级。

## 7. Motion Tokens

| Token | Duration | 场景 |
|---|---|---|
| `fast` | 120~180ms | hover / 小反馈 |
| `normal` | 200~280ms | 列表状态切换 |
| `slow` | 280~340ms | 页面片段过渡 |

规则：
- 禁止无意义长动画。
- 动效只服务“状态变化可感知”。

## 8. 组件规范

1. Sidebar：列宽 `208~244`，行高基线 `26`。  
2. Page Header：标题 + 副标题 + 细分隔线，不再使用重渐变装饰。  
3. Section Group：统一 `controlCenterSectionGroup`，禁止子模块自建阴影风格。  
4. 表单输入：文案层级固定为 `captionStrong -> body/caption`。  
5. Toast：轻卡片、轻阴影，2 行内表达完成。

## 9. 文案规范

1. 普通用户路径：动词开头、短句、一步到位。  
2. 开发者路径：集中在“开发者文档与诊断（可选）”。  
3. 错误提示：先说结果，再给具体动作。

## 10. 反模式

1. 字号跨度过大（视觉断层）。  
2. 同屏出现太多色相。  
3. 圆角档位过多。  
4. 边框、阴影、渐变叠满。  
5. 技术参数默认外露。  
6. 动效拖沓、节奏不稳。

## 11. 调研依据（2026-04-10）

1. Apple HIG（macOS / Typography / Motion / Toolbars / Sidebars / Lists and tables）。  
2. Apple Developer（SwiftUI Material / NavigationSplitView / Settings / Accessibility 环境值）。  
3. Anthropic 官网与 Claude 页面样式结构。  
4. Kimi、Figma 公共页面的样式采样。  
5. GitHub 开源项目：CodeEdit、Applite、Settings、SettingsAccess、isowords、sample-food-truck、charcoal-ios、SBB design system。
