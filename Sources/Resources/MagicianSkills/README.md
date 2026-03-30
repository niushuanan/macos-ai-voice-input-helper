# Magician Skill Catalog

该目录是魔术先生运行期可见的 skill 清单。

- 主文件：`magician-skills.json`
- 用途：供 Agent 的 `skill_search / skill_load_min / skill_invoke` 读取
- 原则：只放最小披露字段，不把整套长文档塞进主上下文

字段说明：

- `id`：skill 唯一标识
- `featureID`：对应产品能力开关（`MagicianFeatureID.rawValue`）
- `domain`：一级/二级域（用于搜索与目录展示）
- `intentScope`：该 skill 的作用边界
- `inputSchema`：输入结构
- `riskNote`：风险说明
- `verifyPolicy`：执行后校验策略
