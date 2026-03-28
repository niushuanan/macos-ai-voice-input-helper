# PulseType 1.1

PulseType 是一个给 macOS 用的 AI 语音输入助手。

它不是输入法皮肤，也不是聊天窗口，而是一个常驻的 helper app：你继续待在当前 app 里，按一下键，说一句话，文字或动作就直接落到眼前的工作流里。

## 它主要解决什么问题

- 聊天、写文档、记会议时，来回切输入法很烦
- 只有普通听写不够，很多时候还想顺手翻译、润色、建日程、记备忘录
- 不同 app 的语气不一样，希望系统能按场景自动处理

## 现在怎么用

- `单击主键`：普通听写
- `长按主键`：魔术先生
- `双击脑暴键`：一口气全念对
- `Esc`：取消当前会话

## 三种工作方式

### 普通听写

说完直接写回当前 app。

如果这个 app 配了个性提示词，PulseType 会按当前场景帮你整理语气、格式和常见脏词，不用每次都自己修。

### 魔术先生

先选中文字，再长按主键说一句命令。

现在已经能做这些事：

- 翻译、润色、扩写、精简、纠错
- 从选中文本里提时间地点并创建日程
- 把选中内容写进备忘录
- 基于选中内容生成邮件草稿

### 一口气全念对

适合连续讲一大段内容。

你可以先把话一口气说完，再让系统帮你整理成更清楚、更像能继续发出去或继续讨论的文本。

## 还有这些能力

- `ASR` 和 `Text` model 可以分开配置
- 默认组合是 `Qwen3-ASR-Flash` + `deepseek-chat`
- 支持本地 `SenseVoice Small`
- 词典保存后立刻生效
- 不同 app 可以配不同提示词
- `记忆` 页能看原文、结果、指令和失败原因
- `HUD` 只显示当前动作，不把内部实现细节堆给你看
- 热键、权限、模型连通测试都在设置页里

## 安装与启动

1. 生成工程

```bash
xcodegen generate
```

2. 安装到 `/Applications`

```bash
./scripts/install-local-app.sh
```

3. 打开 `/Applications/PulseType.app`

4. 在“模型”页填好 `ASR` 和 `Text` 配置，并跑一次连通测试

5. 在“设置”页确认麦克风与辅助功能权限

6. 回到主界面试三种模式

## 适用前提

- 直接写入能力会受不同 app 的 `Accessibility` 实现影响
- 日程、备忘录、邮件这几类动作依赖系统权限和系统 app 可用性
- 本地 `SenseVoice` 需要 runtime 和模型目录
- 目前还是本地开发版，没有签名和公证后的安装包

## 开发与测试

```bash
PULSETYPE_ALLOW_DEBUG_RUNTIME=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  test
```

如需检查本机环境：

```bash
./scripts/doctor-runtime.sh
```
