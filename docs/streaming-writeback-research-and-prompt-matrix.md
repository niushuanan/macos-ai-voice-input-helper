# PulseType 外部流式写回调研与 Prompt 生效矩阵

## 1. 这次调研要回答什么

这次只回答两个问题：

1. `流式输出` 要不要真正出现在外部 app 里，而不是只在 PulseType 自己的 HUD / 控制中心里。
2. 现在仓库里哪些功能真的会吃到模型、吃到哪些 prompt，哪些只是“看起来像会用到”，实际上并没有走进去。

## 2. 先说结论

### 2.1 真实外部流式写回是可以做的

可以，但在 macOS 上其实有两条完全不同的路：

1. **Accessibility 增量写回**
   - 保持 PulseType 还是一个普通 macOS app。
   - 通过 `AXSelectedText` / `AXValue` / `AXSelectedTextRange(s)` 不断把新文本写进当前外部输入框。
   - 优点：不需要把产品改造成真正输入法，能沿用现在的大部分架构。
   - 缺点：这不是真正的 inline composition，没有系统级 marked text，会有兼容性和稳定性边界。

2. **Input Method Kit 真输入法路线**
   - 走 `InputMethodKit`，变成真正的 macOS input method。
   - 通过 `IMKServer` / `IMKInputController` / `updateComposition()` / `setMarkedText(...)` 做真实的 inline composition。
   - 优点：这是最像系统原生输入法的做法，用户能在外部 app 里直接看到“正在组合中的文本”。
   - 缺点：这是架构级改造，不是给当前 PulseType 打个补丁就能完成。

### 2.2 对 PulseType 当前代码来说，更好的路线不是直接做输入法，而是先做“稳定片段增量写回”

当前仓库已经有：

- 前台目标识别
- AX 直写
- 粘贴兜底
- DeepSeek 后处理
- 会话状态机

所以最合适的第一条实现路线是：

`ASR -> DeepSeek 流式文本 -> 只把稳定片段增量写进外部 app`

而不是：

- 每个 token 都立刻写进外部 app
- 或者一次性把整个文本全部替换一遍

### 2.3 你现在看不见“流式”的原因不是你理解错了，而是这版确实没有把流式结果放到外部真实输入框里

现在代码里的流式只到了：

- `SessionStore.liveOutputPreview`
- HUD 标题
- 菜单栏 `help`

最终外部 app 仍然是“完整文本生成完之后，一次性写回”。

所以它现在是：

- **模型侧流式：有**
- **内部状态流式：有**
- **外部真实输入框流式：没有**

## 3. Apple 官方边界

### 3.1 真正的 inline composition 属于输入法体系，不属于 Accessibility 体系

Apple 官方文档里，真正和 marked text、composition 相关的是：

- [InputMethodKit](https://developer.apple.com/documentation/InputMethodKit)
- [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?changes=l_3&language=objc)
- [IMKInputController.updateComposition()](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/1385502-updatecomposition)

这些文档说明的是真输入法如何把“未最终确认的文本”送给当前客户端。

### 3.2 Accessibility 体系能改文本，但它不是输入法的 composition 会话

Apple 官方还明确给了：

- [kAXSelectedTextAttribute](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)
- [kAXSelectedTextRangesAttribute](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangesattribute)
- [kAXValueAttribute](https://developer.apple.com/documentation/applicationservices/kaxvalueattribute)

这说明：

- 可编辑文本元素的当前选中文本、选区、值，理论上都能读写。
- 但这套接口本质上是“辅助功能层的文本修改”，不是“输入法组合态”。

这就是为什么：

- 用 AX 可以做“边说边往外部 app 写字”
- 但很难做到系统输入法那种稳定 marked text 效果

## 4. GitHub / 开源产品现状

这次调研看到的路线很分裂，说明这本身就是个难点。

### 4.1 很多产品宣传“系统级 dictation”，实际主打的是 overlay 预览 + 最终插入

典型例子：

- [TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac)
  - README 里写了 `Streaming preview` 和 `optional live transcript preview where supported`
  - 同时系统级 dictation 用词仍是 `auto-pastes into any app`
- [FluidVoice](https://github.com/altic-dev/FluidVoice)
  - 强调 `Live Preview Mode`
  - 同时强调 `Smart typing directly into any app`

这类产品说明了一件事：

> 很多成熟做法会把“实时预览”和“最终写入”分开处理，而不是在所有 app 里硬做逐 token 内联写回。

### 4.2 也有产品明确宣传“真实外部实时 typing”

典型例子：

- [VoiceToText](https://voicetotext.cc/)
  - 页面明确写了 `typed into Claude Code in real time on macOS`
- [ruudniew/whisper-recorder](https://github.com/ruudniew/whisper-recorder)
  - 公开文案写了 `typing directly where your cursor is`

这说明：

> “外部真实流式写回”在产品上是有人做的，不是幻想。

但这些项目大多是：

- 直接流式 ASR
- 或者本地模型直接出 partial transcript

而不是你现在这条：

`ASR -> DeepSeek 再加工 -> DeepSeek 的最终正文流式返回 -> 再往外写`

后者更难，因为它比 ASR 原始 partial 多了一层语义重写。

## 5. 对 PulseType 最合适的实现路线

## 5.1 不建议继续停在“HUD / 控制中心里流式”

这条路对真实使用价值太弱。

你说得对：

> 如果用户最终是在 Slack、Claude Code、浏览器输入框、飞书、Mail 里工作，那流式价值就必须在这些真实输入场景里体现。

## 5.2 也不建议现在就把 PulseType 改造成真正输入法

原因不是做不到，而是成本太高：

- 产品入口和权限模型会变
- hotkey / menu bar / V4 runtime / agent 能力都要重新和输入法目标协同
- 调试和签名分发复杂度会明显上升

这条线可以做，但应该算 `PulseType 2.0` 级别的架构项目。

## 5.3 最合理的近期方案：外部 app 的“稳定片段增量写回”

建议把流式拆成两个层级：

1. **不稳定尾巴**
   - 只保留在 PulseType 内部状态里
   - 不立刻写进外部 app

2. **稳定片段**
   - 一旦满足稳定条件，就增量追加到外部 app 当前插入点

### 5.3.1 稳定条件建议

可以同时用下面几条：

- 收到句号、逗号、问号、顿号、分号、换行等边界
- 片段长度超过阈值，例如 8 到 16 个字
- 连续 250 到 450ms 没有新内容
- 或者模型明确给出结束信号

### 5.3.2 外部写回策略建议

不要做“全量覆盖式重写”，而要做“增量追加式提交”。

建议维护：

- `committedText`
- `pendingPreviewText`
- `lastCommittedRange`

每次只把：

`newStableText - committedText`

这一段追加到当前外部输入框。

这样可以避免：

- 光标来回跳
- 把用户手动输入的新内容覆盖掉
- Electron / WebView 输入框频繁重绘

### 5.3.3 兼容性策略建议

不要全局一刀切。

建议给目标 app 分三档：

1. **优先支持**
   - `TextEdit`
   - 原生 `AppKit` 文本框
   - 大部分普通 Cocoa 编辑器

2. **谨慎支持**
   - Electron / Chromium 输入框
   - Slack / Feishu / VS Code / 浏览器聊天框

3. **默认回退**
   - Terminal
   - 远程桌面
   - Citrix / VNC / 游戏内输入框

对第 2 类，建议先做灰度开关；对第 3 类，继续保留最终一次性写入。

## 5.4 如果要做到“真正像输入法那样”的体验，长期要走双层架构

更理想的长期形态是：

- `PulseType.app`
  - 菜单栏、设置、历史、模型、Agent、V4 runtime
- `PulseType Input Method`
  - 专门负责真实 inline composition、marked text、候选 / 组合态、外部文本客户端交互

这样你才能同时得到：

- 真正外部可见的流式组合态
- 当前产品已有的模型编排与 agent 能力

## 6. 功能 x Prompt 生效矩阵

下面这张表只按**当前真实代码**写，不按设想写。

### 6.1 用户可配置项

| 功能 / 链路 | `ASR词典` | `口语过滤 spokenFilter` | `个性提示词 systemPrompt` | `按应用风格 appPrompt` | DeepSeek / 文本模型是否真正参与 | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| 普通听写：ASR 阶段 | 是 | 否 | 否 | 否 | 否 | 词典会注入 ASR 请求；见 `SpeechTranscriptionRequest.dictionaryTerms / promptHint / hotwordText` |
| 普通听写：本地清洗 | 否 | 是 | 否 | 否 | 否 | `SkillRuleStore.applyDictation(...)` 在模型前先做口语过滤 |
| 普通听写：DeepSeek 后处理 | 否 | 间接是 | 是，条件触发 | 是，条件触发 | **是，条件触发** | 必须有 `systemPrompt` 或 `appPrompt`，且 `shouldUseTextProcessing(...)` 返回 true |
| 普通听写：最终写回 | 否 | 否 | 否 | 否 | 否 | 这里只负责把最终文本写进外部 app |
| 讨论整理 Brainstorm | 否 | 是，先本地过滤 | 是 | 是 | **是** | 模型输出 `summary + dialogue`，是结构化 prompt 的强使用场景 |
| 魔术先生：命令语义预处理（音乐 / 飞书） | 间接是 | 是，可清洗命令 | 否 | 否 | **是，按需** | 这里吃的是内部场景 prompt，不吃全局 system/app prompt |
| 魔术先生：入口语义路由 | 否 | 否 | 否 | 否 | **是** | `MagicianSemanticLaneRouter` 决定 native_fast / agent / selection_mode |
| 魔术先生：V4 planner | 否 | 否 | 否 | 否 | **是** | `V4PlannerLLM` 决定 channel 与下一步 step |
| 魔术先生：纯文本改写 / text.transform | 否 | 视上游命令而定 | **当前不稳定透传，默认不要指望** | **当前不稳定透传，默认不要指望** | 是 | 当前不要假设全局 prompt 会自动影响 text.transform |
| 音乐执行结果解读 | 否 | 否 | 否 | 否 | 按模型可用性决定 | 模型不可用时会退回 fallbackInterpretation |

### 6.2 内部系统 Prompt

| 功能 / 链路 | 内部 prompt 是否存在 | 作用 |
| --- | --- | --- |
| 普通听写后处理 | 是 | 让模型扮演 `precise dictation cleanup engine`，只返回最终文本 |
| 讨论整理 Brainstorm | 是 | 强约束为 JSON，产出 `summaryPoints` 和 `dialogueLines` |
| 魔术先生命令预处理 | 是 | 音乐 / 飞书 / generic 三类场景各有单独 prompt |
| 魔术先生入口路由 | 是 | 强制模型只输出 lane/path/selection_mode 的 JSON |
| V4 planner | 是 | 强制模型只规划下一步，不直接产出最终结果 |
| 音乐执行解读 | 是 | 要求输出 3 段中文说明，不允许编造 |

## 7. 这张矩阵对应的产品判断

### 7.1 你现在最有价值的 prompt，不是“所有地方通用的一句神 prompt”

真正有价值的是这些：

- 普通听写后的 `dictation cleanup prompt`
- Brainstorm 的结构化 JSON prompt
- 魔术先生的场景命令纠错 prompt
- lane router 的判路 prompt
- V4 planner 的下一步规划 prompt

这些 prompt 都是在**定义产品机制**，不是只做文风修饰。

### 7.2 目前最弱的一块，是“用户以为全局 prompt 会统一影响所有功能”

这在当前仓库里并不成立。

尤其是：

- `systemPrompt`
- `appPrompt`

它们主要稳定生效在：

- 普通听写后处理
- Brainstorm

而不是自动覆盖魔术先生所有文本变换。

所以产品上要么：

1. 把这件事讲清楚；
2. 要么后续把 prompt 注入矩阵统一起来。

## 8. 下一步最值得做什么

### 8.1 第一优先：做外部 app 里的稳定片段流式写回

这是最符合你当前产品定位的。

目标不是“技术上 SSE 通了”，而是：

> 用户在 Claude Code、Slack、浏览器输入框里，能明显看到文本在生成和进入输入框。

### 8.2 第二优先：把 prompt 生效矩阵代码化，而不是只靠文档记忆

建议后续把 prompt 注入权限整理成一张真正的 routing matrix，例如：

- 哪个 lane
- 哪个 feature
- 哪个 prompt source
- 是否允许透传
- 透传到哪个 provider

这样以后改功能时不会再出现“我以为它会生效，结果其实没走到”的问题。

### 8.3 第三优先：给历史和诊断补“本次是否真的用了文本模型”

对普通听写尤其重要。

建议后续直接给 history / diagnostics 增加：

- `didUseRewriteModel`
- `rewriteProvider`
- `rewriteModel`
- `rewriteRoute`

这样你每次都能直接确认：

- 这次是不是 DeepSeek 真处理了
- 还是只走了 ASR + 本地过滤

## 9. 对当前仓库的明确建议

### 建议路线

短期：

- 保持 `PulseType.app` 架构不变
- 在当前 `AccessibilityTextOutputCoordinator` 上补“稳定片段增量写回”
- 给高风险 app 做白名单 / 灰度开关

中期：

- 补控制中心里的真实流式面板
- 补 history / diagnostics 的模型使用记录
- 把 prompt 注入矩阵统一化

长期：

- 评估 `InputMethodKit` companion target
- 如果要做到真正输入法级 inline composition，再单独开一条产品线
