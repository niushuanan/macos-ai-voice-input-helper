# PulseType 流式语音内核重写设计

## 1. 产品目标

PulseType 的操作方式和前端视觉保持基本不变：用户按下快捷键、说话、松手，最终文本可靠地进入原来的目标输入框。

本次重写改变的是内核时序：录音、上传、识别和文本整理必须在用户说话期间并行推进，松手只负责冲刷最后一小段，而不是从零开始处理整段录音。

最终主链必须同时满足：

- 快：长语音不再导致松手后的等待时间线性增加。
- 准：继续使用中文效果稳定的云端 ASR，并使用词典和上下文增强。
- 稳：外部 App 默认仍然一次性原子写回，不把不稳定的中间文本直接写进去。
- 深度结合 LLM：LLM 在录音期间处理稳定片段，而不是 ASR 全文完成后再串行处理全文。
- 可恢复：实时链路失败时保留录音文件，自动回退到现有批量 ASR。
- 少概念：不新增用户必须理解的模式、页面或技术选项。

## 2. 已验证的现状与根因

当前普通听写是完全串行的：

1. `AVAudioRecorderCaptureService` 先录制完整 WAV。
2. 用户松手后 `stopRecording()` 才返回 `RecordedAudioClip`。
3. `DashScopeQwenASRProvider` 读取整个文件并编码为 Base64。
4. 完整 ASR 返回后，长于 10 个字符的常见听写再次进入全文 LLM。
5. LLM 完整输出后才写回目标 App。

本机诊断日志的 112 条成功样本显示，音频时长与 ASR 延迟相关系数约为 0.96；10 秒以下、10～30 秒、30～60 秒和 60 秒以上语音的总耗时中位数依次约为 1.73、2.80、4.69、7.77 秒。这证明问题主要来自处理时序，不是界面动画。

本机对 Typeless 2.4.0 的只读静态检查确认其客户端存在连续 Opus 分块、WebSocket 会话和 streaming 通道，且应用包内没有发现本地 ASR 模型。该证据只说明客户端具备边录边传能力，不推断其私有服务端模型。

## 3. 架构选择

采用“云端实时主链 + 批量保底 + 可选本地保底”的混合架构：

- 默认主链：Qwen3 ASR Realtime WebSocket，16kHz 单声道 PCM。
- 第一保底：现有 Qwen 批量接口，使用同一录音会话落盘的 WAV。
- macOS 26 本地能力：作为后续可插拔 provider，不让它阻塞主链交付；macOS 14 仍然完整可用。
- LLM：稳定片段并行编辑，最终尾段在有限时间预算内完成。

不采用以下路线：

- 继续优化整文件上传：不能消除语音长度和松手延迟之间的结构性关系。
- 立刻改成 InputMethodKit 输入法：会引入新的安装、权限、兼容和候选窗口问题，不能直接提高识别速度。
- 把 LLM 的流式 token 直接持续写进任意外部输入框：WebView 和富文本编辑器已经出现前文丢失，只保留内部 HUD 预览和最终原子写回。
- 第一版引入本地大模型 ASR：模型体积、中文效果和依赖成本都会扩大风险；provider 协议保留后续接入能力。

## 4. 新的运行时数据流

```text
快捷键开始
  ├─ 冻结目标 App / 选中文本 / 场景提示 / 个人词典
  ├─ 建立 Qwen Realtime WebSocket
  └─ AVAudioEngine 开始产生 PCM chunk
        ├─ chunk 写入有界实时队列 → WebSocket
        ├─ chunk 串行写入临时 WAV → 批量回退
        └─ 音量更新 → 现有 HUD

ASR delta / completed
  └─ TranscriptLedger
       ├─ committed：服务端确认，不再随意修改
       └─ tentative：当前可变化尾巴，只用于内部预览

稳定片段
  └─ SemanticEditor
       ├─ 带 App、提示词、词典和最近上下文调用 LLM
       ├─ 结果按 segmentID / revision 回填
       └─ 事实保护失败或超时 → 使用原 ASR 片段

快捷键结束
  ├─ 停止采集并排空已产生 chunk
  ├─ session.finish，等待最后 completed
  ├─ 在短预算内收齐语义编辑结果
  └─ 合并文本 → 现有 TextOutputCoordinator 原子写回

实时失败
  └─ 关闭实时会话 → 使用已落盘 WAV 调现有批量 ASR → 原有后处理/写回
```

## 5. 文件与职责边界

### 5.1 `Sources/Core/VoiceKernel/VoiceKernelTypes.swift`

只放跨组件数据合同：

- `VoiceSessionContext`
- `VoiceAudioChunk`
- `StreamingTranscriptEvent`
- `VoiceKernelUpdate`
- `VoiceKernelResult`
- `VoiceKernelFailure`

这些类型不依赖 UI，也不暴露 Qwen 的 JSON 字段。

### 5.2 `Sources/Core/VoiceKernel/TranscriptLedger.swift`

纯 Swift 文本账本：

- 按 ASR item ID 管理 delta 和 completed。
- completed 结果是对应 item 的权威文本。
- 产生“已确认全文 + 当前临时尾巴”的快照。
- 忽略过期 revision，避免旧异步结果覆盖新文本。
- 最终合并时保持顺序且不重复。

### 5.3 `RealtimeASRSession` 协议

协议与实现同放在 `Sources/Core/VoiceKernel/QwenRealtimeASRSession.swift`，避免为一个小合同额外增加文件。

定义实时 provider 协议：

```swift
protocol RealtimeASRSession: Sendable {
    var events: AsyncThrowingStream<StreamingTranscriptEvent, Error> { get }
    func start(context: VoiceSessionContext) async throws
    func append(_ chunk: VoiceAudioChunk) async throws
    func finish() async throws
    func cancel() async
}
```

协议表达一次录音对应一次实时会话，不把连接复用强塞给不支持复用的 provider。

### 5.4 `Sources/Core/VoiceKernel/QwenRealtimeASRSession.swift`

负责：

- 把现有 HTTP base URL 解析为实时 WebSocket endpoint。
- 使用现有凭据存储中的 API Key 设置 `Authorization`。
- 发送 `session.update` 和连续 `input_audio_buffer.append`。
- 使用 server VAD，默认 `silence_duration_ms = 400`、`threshold = 0.0`。
- 把个人词典和场景上下文放入 `input_audio_transcription.corpus.text`。
- 解析 delta、completed、session.finished 和 error。
- 用户松手时发送 `session.finish`，等待服务端最终结果。

事件解析器必须与网络传输分离，单元测试直接喂 JSON，不连接真实服务。

### 5.5 `Sources/Core/VoiceKernel/StreamingAudioCaptureService.swift`

使用 `AVAudioEngine` 代替 `AVAudioRecorder` 作为新主链：

- 麦克风输入转换为 16kHz、16-bit、单声道 PCM。
- 以约 40～100ms 为一个 chunk。
- 音频回调只复制 buffer 并交给专用串行队列，不切到 MainActor。
- 通过有界 `AsyncStream` 输出 chunk；队列溢出视为实时链路失败，不能静默丢音频。
- 同一份转换后 PCM 串行写入临时 WAV，供回退使用。
- 保留现有音量 publisher 和临时文件清理语义。

### 5.6 `Sources/Core/VoiceKernel/SemanticEditor.swift`

LLM 在普通听写中的职责是“保守编辑器”，不是聊天机器人：

- 允许修正错别字、口语赘词、标点、大小写和轻量结构。
- 不回答文本中的问题，不执行命令，不补充事实，不改变语义顺序。
- 每个请求带 `segmentID`、source revision、目标 App 和最近已确认上下文。
- 同一 segment 的旧任务在 source revision 改变后作废。
- 结果为空、超时或不满足事实保护时退回源文本。

事实保护至少覆盖：

- 阿拉伯数字和带单位数字。
- 英文 token、邮箱、URL、文件路径和代码标识符。
- 中文否定词：不、没、未、别、不要、无需、不能、禁止。
- ASR 个人词典中命中的词。

### 5.7 `Sources/Core/VoiceKernel/VoiceInputKernel.swift`

一个 actor 负责单次语音会话的并发编排：

- `start(context:)`：并发启动捕获、实时 ASR 和事件消费。
- `stop()`：先停止捕获，再排空发送队列，再结束 ASR，然后收敛 LLM 结果。
- `cancel()`：取消所有子任务并删除临时文件。
- 实时失败时返回明确的 fallback clip，让上层只执行一次批量回退。
- 所有任务都归属于当前 session ID，旧 session 不能污染新 session。

### 5.8 现有模块的调整

- `AppModel`：装配新 capture、Qwen realtime session factory、SemanticEditor 和 VoiceInputKernel。
- `InteractionCoordinator`：保留产品 lane、权限、Agent 路由、历史和写回职责；录音与转写不再自行串行编排，而是调用 VoiceInputKernel。
- `SessionStore`：接收新内核的实时预览和阶段更新，不增加用户可见的新模式。
- `SpeechProviderRegistry` 和现有 batch provider：保留为配置、连接测试和实时失败时的回退。
- `TextOutputCoordinator`：继续负责最终原子写回；默认不扩大外部增量写白名单。

## 6. 状态机与并发不变量

状态：

```text
idle → starting → listening → finishing → delivered → idle
                  └──────────→ fallbackBatch → delivered
任意活动状态 ────→ cancelled / failed → idle
```

必须保证：

- 同一时刻最多一个活动语音 session。
- 上层状态机只会发起一次 `stop()`；内核对非活动会话的重复结束请求直接拒绝。
- `cancel()` 之后任何网络、ASR 或 LLM 回调都不能写回文本。
- finish 前已经产生的音频 chunk 必须先于 `session.finish` 发送。
- 队列溢出、WebSocket 断开、服务端 error 和最终结果超时都进入同一个可解释的 fallback 路径。
- 最终外部写回最多一次；历史只保存最终实际写出的文本。

## 7. LLM 时延策略

LLM 与 ASR 的结合采用“提前做、有限等、失败退回”：

- ASR completed 片段立即进入 LLM。
- tentative 片段不进入 LLM，避免可变文本造成重复请求和旧结果覆盖。
- 片段按原顺序合并，允许并行生成但不允许乱序写入。
- 松手后普通听写最多等待 0.8 秒收齐语义编辑；超时片段直接使用原 ASR 文本。
- 魔术先生和讨论整理继续允许完整模型过程，因为它们的产品结果本来不是即时原子听写。

该策略让长语音的大部分 LLM 时间被用户说话时间覆盖，同时保证短语音不会无限等待。

## 8. 失败恢复

- 连接未建立：本地继续录音；停止后直接批量 ASR。
- 发送中断：停止向实时 provider 发送，继续保留本地 WAV；停止后批量 ASR。
- 实时返回空文本：批量 ASR。
- LLM 失败：使用原 ASR + 本地规则，不重试整篇。
- 写回失败：保持现有剪贴板兜底和明确提示。
- App 在录音期间切换：仍写回录音开始时冻结的目标，避免落入错误窗口。

## 9. 可观测性

每个 session 继续使用现有 trace ID 串联，新增关键节点 `voice.stop`、`asr.first_delta`、`asr.segment.completed`、`asr.realtime.success`、`realtime.fallback.activated` 和 `asr.realtime.fallback`，并复用现有批量 ASR 与 `write.success/failed` 日志。

新日志只记录文本长度、完成片段数、音频时长、provider 和经过清洗的 fallback 原因；不记录原文、音频或凭据。

## 10. 验收标准

### 10.1 自动化

- TranscriptLedger 能正确处理 delta、completed、多个 item、重复事件和过期事件。
- Qwen JSON 解析覆盖正常、空 transcript、服务端 error 和 session.finished。
- finish 严格发生在最后一个 chunk 发送之后。
- 实时连接/发送/最终结果失败时只触发一次批量 fallback。
- LLM 旧 revision 不覆盖新 revision。
- 数字、英文 token、否定词和词典词被改坏时退回源文本。
- cancel 后不会产生写回。
- 最终文本只写回一次。

### 10.2 性能目标

稳定网络、正常中文口述：

- 首个可见 ASR 预览：中位目标不超过 1.2 秒，P90 不超过 2 秒。
- 5 秒以上普通听写 stop-to-write：中位目标不超过 1 秒，P90 不超过 2 秒。
- 10、30、60、120 秒语音分桶的 stop-to-write 中位数最大差值不超过 500ms。
- 正常链路无 chunk 丢失、重复文本和重复写回。

性能目标是实际验收指标，不是仅靠单元测试声明完成。

### 10.3 真实产品路径

- TextEdit：普通文本框。
- Safari 或 Chrome：网页输入框。
- Codex：富文本/编辑器场景。
- 飞书或其他 Electron App：富文本场景。
- 真实短句、30 秒口述、60 秒以上连续口述。
- 录音中断网，验证批量回退仍能得到文本。

## 11. 安全与隐私

- API Key 继续只从应用现有凭据存储读取，不进入日志、测试 fixture 或文档。
- 临时 WAV 在成功或明确取消后删除；失败恢复期间保留到回退结束。
- 诊断日志不记录音频和完整文本。
- 不复制 Typeless 私有实现代码，只使用本机静态检查得到的产品级架构证据。

## 12. 发布约束

- 保持 bundle identifier 和现有权限，避免安装后重新丢失 Accessibility 授权。
- 使用 Xcode 26.6，但部署目标保持 macOS 14.0。
- 只增加完成主链所需的文件和测试，不顺带重构 V4 Agent 与前端页面。
- 最终统一执行 `test → commit → push → install`。
- 遵从用户要求：本次中途不提交，全部验收结束后只创建一次新 commit，并只 push 一次。
