# Provider 接入与测试（双角色固定版）

## 本轮目标

用最短路径让用户在前端完成两条模型链路配置并立即自测：

1. 语音识别（ASR）
2. 文本处理（Rewrite / Text Generation）

## 配置结构

`ProviderSettingsStore` 已从多 profile 模式改成双角色固定配置：

- `ASRConfig { providerType, baseURL, model, keyRef }`
- `TextConfig { providerType, baseURL, model, keyRef }`

两套配置都支持：

- `OpenAI（官方）`
- `OpenAI 兼容`

## OpenAI 兼容接口约定

- ASR：`POST {baseURL}/v1/audio/transcriptions`
- 文本：`POST {baseURL}/v1/chat/completions`

地址统一通过 `OpenAIEndpointResolver` 规范化，避免 `/v1/v1` 重复路径。

## 密钥存储策略

- API 密钥只保存在 macOS 钥匙串（Keychain）。
- `UserDefaults` 仅保存非敏感元数据（provider 类型、base URL、model、keyRef）。
- 兼容旧版本 profile 配置时，会自动迁移可用密钥到新 keyRef。

## 前端测试能力

设置页每张卡片都提供“测试”按钮。

### 测试ASR

- 使用内置短 WAV 音频样本发起真实请求。
- 返回统一结果：
  - 成功/失败
  - HTTP 状态码
  - 可读消息
  - 建议动作（密钥/地址/模型/额度）

### 测试文本模型

- 发送固定短提示词到 `/v1/chat/completions`。
- 校验返回内容可解析，并给出同样的统一结果结构。

统一返回类型：

- `ConnectionTestResult { status, message, hint, timestamp, httpStatus }`

## 当前限制

- 只走 OpenAI 兼容协议主线，不做多厂商原生协议深度适配。
- 暂未开放温度、top_p 等高级参数。
- 测试按钮验证的是“接口可用性”，不代表业务结果质量上限。
