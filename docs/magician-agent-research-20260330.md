# 魔术先生 Agent 调研与重构映射（2026-03-30）

## 1. 调研范围

- `shareAI-lab/learn-claude-code`（重点 `s01/s02/s03`）
- Anthropic: [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
- Anthropic Docs: [Tool use overview](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview)
- OpenAI Docs: [Migrate to Responses API](https://developers.openai.com/api/docs/guides/migrate-to-responses/)
- OpenAI Cookbook: [Reasoning function calls](https://developers.openai.com/cookbook/examples/reasoning_function_calls/)

## 2. 最新共识（和你目标一致的部分）

1. Agent 核心不是脚本路由，而是 **LLM 驱动的循环**：`plan/reason -> tool_use -> tool_result -> continue/stop`。
2. Tool 扩展方式应该是 **注册+分发**，而不是在主循环写关键词分支。
3. 多步任务需要 **todo 状态机**，并保证同时只有一个 `in_progress`。
4. 上下文工程要做 **选择性披露**：主上下文放最小索引，细节按需加载。
5. 真 Agent 需要 **可观测性**：每步调用、证据、失败轨迹都能回放。

## 3. 对魔术先生的落地映射

- 你的固定流程：
  - `ASR + text model` 预处理
  - `Intent LLM` 生成结构化 `todo + steps`
  - `Agent loop` 执行 `skill_search -> skill_load_min -> skill_invoke -> verify`
  - 每步证据回灌给 `Intent LLM` 决定继续/结束
- 已保证：无真实 LLM/网络场景下，V3 内核直接失败，不做本地兜底。

## 4. 本次代码重构（不改主能力）

1. 内核新增 `core.reason.respond` 内建能力：
   - 纯文本推理/翻译/解释优先走内建推理，不强绑外部 skill。
2. skill 选择失败问题治理：
   - 当无匹配 skill 时，优先降到 `core.reason.respond`，避免 `skill_id` 为空。
3. 选择性披露强化：
   - 新增一级域索引（`domainTier1Summary`）供 plan 使用；
   - router 搜索索引按域截断（`searchIndexSummary`），减少上下文体积。
4. 多步链路增强：
   - 自动把上一步输出注入 `previous_output`，提高“翻译后继续执行下一步”成功率。
5. 代码梳理归类：
   - 在内核文件中按 `Contracts / Todo+Catalog / Router / Runtime / Helpers` 分段。

## 5. 结论

你要求的方向是对的：
- **推理优先**（模型先判断）
- **外部动作才调 skill**
- **一步一证据**
- **失败可追踪**

这套方式确实比“关键词脚本机”更能处理未知任务，尤其是跨步骤组合任务。
