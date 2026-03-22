# API 密钥与模型配置说明

## 安全基线（长期可用）

- API 密钥只写入 macOS 钥匙串（Keychain），不会写入仓库文件。
- `UserDefaults` 仅保存非敏感配置（Provider、地址、模型、测试结果）。
- 本地历史记录不会保存密钥明文。
- 仓库内提供密钥扫描脚本与 pre-commit 检查，降低误提交风险。

## 默认模型配置（新安装）

首次运行且没有旧配置时，默认会给出以下组合：

1. ASR（语音识别）
   - Provider：`DashScope Qwen ASR`
   - 地址：`https://dashscope.aliyuncs.com`
   - 模型：`qwen3-asr-flash`
2. 文本处理
   - Provider：`OpenAI 兼容`
   - 地址：`https://api.deepseek.com`
   - 模型：`deepseek-chat`

如果你已经有旧配置，系统不会强制覆盖。

## 本地初始化密钥（两种方式）

推荐方式（更稳定）：先用 `./scripts/install-local-app.sh` 安装到 `/Applications/PulseType.app`，再直接在 App 的 `模型` 页面输入并保存。  
兼容方式：运行脚本批量写入 Keychain。

在项目根目录执行：

```bash
./scripts/setup-local-keys.sh
```

脚本会交互录入两把密钥，并写入 Keychain v4 服务：

- 服务名：`com.niushuanan.PulseType.provider-profile.v4`
- ASR key：`asr.primary`
- 文本 key：`text.primary`

如果脚本写入后状态仍异常，以 App 内重新保存为准。

可选：安装提交前密钥扫描钩子：

```bash
./scripts/install-pre-commit-hook.sh
```

## 前端模型页怎么填

模型页固定两张卡片：`ASR` 与 `文本处理`。

- ASR 支持：
  - DashScope Qwen ASR（云端）
  - OpenAI / OpenAI 兼容（云端）
  - 本地 SenseVoice（实验）
- 文本处理支持：
  - OpenAI / OpenAI 兼容（DeepSeek 默认走这条）

每张卡片都可查看“当前生效配置”与“最近测试结果”。

## SenseVoice（实验）配置

如果切换到本地 SenseVoice：

- 默认模型目录：
  `~/Library/Application Support/Shandianshuo/models/sensevoice-small`
- 可在模型页改成本机自定义路径
- 模型页会显示可用性检测结果：
  - 模型文件缺失
  - Python 依赖缺失
  - 执行异常

依赖或模型不完整时，只影响该本地选项，不影响云端 ASR 主路径。

## 自测步骤

1. 在 ASR 卡片点“测试 ASR”。
2. 在文本卡片点“测试文本模型”。
3. 查看最近结果中的：
   - 成功/失败
   - HTTP 状态
   - 可执行建议（地址/模型/密钥/额度/网络）

## 常见问题

- 401：密钥错误、未保存或额度策略不允许。
- 404：地址或路径不对。
- 429：额度不足或触发限流。
- 本地 SenseVoice 失败：模型目录不完整，或本地运行环境还没准备完成。
