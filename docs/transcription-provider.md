# Provider 接入与测试（双角色固定版）

## 本轮目标

用最短路径让用户在前端完成两条模型链路配置并立即自测：

1. 语音识别（ASR）
2. 文本处理（Rewrite / Text Generation）

## 配置结构

`ProviderSettingsStore` 已从多 profile 模式改成双角色固定配置：

- `ASRConfig { providerType, baseURL, model, keyRef }`
- `TextConfig { providerType, baseURL, model, keyRef }`

ASR 支持：

- `DashScope Qwen ASR`
- `OpenAI（官方）`
- `OpenAI 兼容`
- `本地 SenseVoice（实验）`

文本处理支持：

- `OpenAI（官方）`
- `OpenAI 兼容`

## 云端接口约定

- ASR：`POST {baseURL}/v1/audio/transcriptions`
- 文本：`POST {baseURL}/v1/chat/completions`

DashScope Qwen ASR（官方）：

- `POST {baseURL}/api/v1/services/aigc/multimodal-generation/generation`
- 输入音频按 `data:audio/wav;base64,...` 传入
- 返回解析 `output.choices[0].message.content[*].text`

地址统一通过 `OpenAIEndpointResolver` 规范化，避免 `/v1/v1` 重复路径。

## 密钥存储策略

- API 密钥保存在本地应用目录（`~/Library/Application Support/PulseType/Credentials/credentials.v1.json`）。
- `UserDefaults` 仅保存非敏感元数据（provider 类型、base URL、model、keyRef）。
- 兼容旧版本 profile 配置时，会自动尝试迁移旧密钥；迁移后统一走本地存储。

## 前端测试能力

设置页每张卡片都提供“测试”按钮。

### 测试ASR

- 使用内置短 WAV 音频样本发起真实请求。
- 返回统一结果：
  - 成功/失败
  - HTTP 状态码
  - 可读消息
  - 建议动作（密钥/地址/模型/额度）
- 本地 SenseVoice 走可用性检测：
  - 模型目录是否存在
  - 必需文件是否齐全
  - Python 依赖是否可用

### 测试文本模型

- 发送固定短提示词到 `/v1/chat/completions`。
- 校验返回内容可解析，并给出同样的统一结果结构。

统一返回类型：

- `ConnectionTestResult { status, message, hint, timestamp, httpStatus }`

## 当前限制

- DashScope Qwen ASR 已支持官方协议；其它厂商仍以 OpenAI 兼容为主线。
- 本地 SenseVoice 处于实验阶段，依赖与模型准备由本机环境决定。
- 暂未开放温度、top_p 等高级参数。
- 测试按钮验证的是“接口可用性”，不代表业务结果质量上限。
