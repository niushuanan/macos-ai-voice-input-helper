# PulseType

PulseType 是一个给 macOS 用的 AI 语音输入助手。它不是系统输入法，而是独立 app。

## 这是啥

你可以把它理解成“键盘优先”的语音输入工具：

- 用全局热键开始/结束语音输入
- 语音先转文字，再写入当前焦点 app
- 在选中文本上做改写（翻译、润色、精简、结构化）
- 通过不同 app 的提示词策略，让输出更贴场景

## 现在能做什么

- 全局热键：唤醒键 + 取消键
- 本地录音 + 云端 ASR
- 听写文本自动写回前台 app
- 双模型配置：`ASR` + `Text`
- 默认模型组合：`Qwen3-ASR-Flash` + `deepseek-chat`
- 可切到本地 ASR：`SenseVoice Small`
- 模型连接一键测试
- 本地词典：每行一个词条，保存后立刻生效
- 本地记录：筛选、复制、删除、清空
- 权限中心：麦克风与辅助功能状态检查
- 菜单栏 + 主窗口 + HUD 状态提示

## 页面说明

- `首页`：会话状态、近期内容、累计指标
- `记忆`：本地记录列表与筛选管理
- `Skill`：口语过滤、个性提示词、按 app 风格策略
- `词典`：ASR 词条配置
- `模型`：ASR/Text 参数、密钥与连通测试
- `设置`：热键、权限、运行诊断、关于
- `Agent-头脑风暴（Beta）`：短时讨论记录与整理入口

## 快速开始

1. 生成工程

```bash
xcodegen generate
```

2. 覆盖安装到 `/Applications`

```bash
./scripts/install-local-app.sh
```

3. 打开 `/Applications/PulseType.app`

4. 在 `模型` 页填好配置并测试连通

5. 在 `设置` 页确认麦克风与辅助功能权限

6. 回到 `首页`，用热键开始体验

## 已知限制

- 目前仅在部分 app 场景做过重点验证
- 直接写入路径在不同 app 上存在差异
- 本地 `SenseVoice` 依赖本机 runtime 与模型目录
- 目前还没有签名/公证后的发行安装包

## 开发与测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  test
```

如需排查运行环境：

```bash
./scripts/doctor-runtime.sh
```
