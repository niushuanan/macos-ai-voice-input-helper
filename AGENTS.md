# AGENTS.md

适用范围：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法`

## 沟通规范

- 除 technical terms 外，全部使用中文。
- 用白话表达，避免黑话。

## 默认执行规则

- 代码任务完成且存在改动时，默认执行自动发布链路：`test -> commit -> push -> install`。
- 若用户明确说“不要发布”或“仅改代码”，当次跳过发布链路。

## 自动发布链路

- 统一命令：

```bash
scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...]
```

- 可选跳过安装：

```bash
scripts/auto-ship.sh --message "<commit message>" --files <file1> [file2 ...] --skip-install
```

## 质量门禁

- 必须先过测试，再允许 push 与安装。
- push 失败按脚本重试策略执行，失败即报错并停止。
- 仅提交明确列出的文件，避免无关文件进入 commit。
