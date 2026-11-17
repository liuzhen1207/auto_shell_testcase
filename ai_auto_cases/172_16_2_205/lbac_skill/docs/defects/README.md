# LBAC 缺陷/文档说明目录

| 文件 | 性质 | 状态 | 是否提 PLM |
| --- | --- | --- | --- |
| `DEFECT_array_add_element_position.md` | **文档修正说明（非缺陷）** | 已定稿（2026-11-17） | 不提 |
| `DEFECT_set_tree_multi_value_label.md` | **已撤回**（结论有误） | 撤回说明（2026-11-17） | 不提 |

## 1. ARRAY / TREE `ADD ELEMENT` 位置子句

- **结论**：省略位置子句返回 `2410`（ARRAY `requires an ArrayElementClause` / TREE `requires a TreeElementClause`）是**正确行为**；
- **需要修正**：需求文档 L164-165（语法里的 `?`）与研发自测文档 **C-14**（原期望“默认追加”，应改为负向断言 2410）；
- 详见文件内表格；我方用例 LB-164 已固化该行为（含 TREE）。

## 2. SET / TREE 多值标签

- **撤回原因**：多值**是支持的**，正确写法为需求 L634 示例 `COMPONENT dept 'RD', 'QA'`；
- 当初误判是因为尝试了三种非规范写法（空格分隔 / 括号 / 重复 COMPONENT）；
- 保留文件仅记录“语法易混淆点”（逗号双重含义、`(RD,QA)` 是展示格式而非 SQL 写法、多值 `label_value` 展示顺序被重排）；
- 我方用例 LB-196（SET 多值覆盖）、LB-197（TREE 多值多分支）已改为真实用例。

## 3. 仅保留在仓库

按 2026-11-17 决定：这两份材料**只保留在仓库**，不同步到 Feishu 自测文档，也不提交 PLM。
需要时由文档负责人据此更新需求页与自测文档。
