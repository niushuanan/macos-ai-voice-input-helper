# PulseType 2.0

PulseType 是一个 macOS 常驻语音助手。你不用切输入法，也不用切窗口，按键开口就能把内容直接写进当前 app。

2.0 的方向很明确：把“说一句就能办完一件事”做实，覆盖写字、改写、系统动作、CLI 动作四类场景。

## 2.0 现在能做什么

### 三种交互模式

- `主键单击`：普通语音（开始/结束）
- `主键长按（>=180ms）`：魔术先生（按住说，松开执行）
- `脑暴键双击（<=350ms）`：一口气全念对
- `Esc`：取消当前会话

默认主键与脑暴键都是 `右 Shift`，可在设置页调整。

### 魔术先生（2.0 核心）

有选中时：

- 翻译、润色、扩写、精简、纠错
- 按选中内容建日程
- 写入备忘录
- 整理邮件（地址明确时可直接发，不明确时仅打开 Mail 编辑）

无选中时：

- 作为文本命令助手直接生成内容
- 在开启 `CLI 模式（飞书）` 后，可直接语音下令执行飞书 CLI 动作

另外还支持一句话控制 Music（播放、暂停、继续、切歌）。

### 一口气全念对

面向短时讨论或多人脑暴。你先完整说完，系统会自动整理成更适合下一步给 AI 分析的上下文，同时放进输入框和剪贴板。

## 控制台页面（当前产品形态）

- `首页`：核心能力说明 + 历史效率统计
- `记忆`：本地会话记录筛选、复制、删除
- `词典`：ASR 热词（每行一个，保存后马上生效）
- `Skill`：规则开关与参数（含按应用风格策略）
- `模型`：`ASR / 文本处理 / CLI 模式（Agent）` 三路独立配置与连通测试
- `魔术先生`：文本权限、飞书 CLI、苹果原生能力统一配置
- `一口气全念对`：触发方式与模型建议时长
- `设置`：快捷键、权限中心、运行状态提示

## 模型与默认配置

- `ASR` 默认：`阿里云 Qwen ASR`（`qwen3-asr-flash`）
- `文本处理` 默认：`OpenAI 兼容`（`https://api.deepseek.com` / `deepseek-chat`）
- `CLI 模式（Agent）` 默认：同上，可单独改
- 可切换本地 `SenseVoice`（含环境准备与健康检测）

## 安装与启动

1. 生成工程

```bash
xcodegen generate
```

2. 安装到 `/Applications/PulseType.app`

```bash
./scripts/install-local-app.sh
```

3. 打开 `/Applications/PulseType.app`

4. 在“模型”页填好密钥并完成三路连通测试

5. 在“设置”页确认麦克风与辅助功能权限

6. 试跑三种交互模式

## 本地优先与边界

- 记录与配置默认保存在本地目录
- 写字与改写依赖目标 app 的 Accessibility 实现
- 日程、备忘录、邮件、音乐能力依赖系统权限与本机 app 可用性
- 当前依旧是本地开发安装形态，暂无签名公证安装包

## 开发测试

```bash
PULSETYPE_ALLOW_DEBUG_RUNTIME=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  test
```

环境检查：

```bash
./scripts/doctor-runtime.sh
```
