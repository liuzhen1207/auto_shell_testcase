# 文档修正说明（非缺陷）：ARRAY / TREE 组件 `ADD ELEMENT` 必须带位置子句，省略返回 2410

> 结论（2026-11-17 定稿）：**实现行为（被拒 2410）即为正确行为**，不提产品缺陷；需要修正的是**需求文档语法定义**与**研发自测用例 C-14**。
> 状态：待文档负责人确认后更新需求页 / 自测文档；我方用例已按此口径固化。

## 一、实现的正确行为（已实测）

| 组件类型 | `ADD ELEMENT 'C'`（不写位置子句） | 错误码 | 正确写法 |
|---|---|---|---|
| ARRAY | **被拒** | `2410: ARRAY component 'zz_arr' requires an ArrayElementClause` | `ADD ELEMENT 'C' AFTER 'B'` / `BEFORE 'A'` |
| TREE | **被拒** | `2410: TREE component 'om_tree' requires a TreeElementClause` | `ADD ELEMENT 'C' UNDER 'A'`（OVER 只能与 UNDER 组合） |
| SET | 允许 | — | `ADD ELEMENT 'C'`（SET 无顺序，不接受 BEFORE/AFTER/UNDER） |

补充：TREE 的 `OVER` 不能单独使用（`ADD ELEMENT 'D' OVER 'A'` → 700，须写成 `UNDER <parent> OVER <siblings>`）。

## 二、需要修正的文档

### 2.1 需求文档（PingCode LBAC）

| 位置 | 现状 | 建议 |
|---|---|---|
| L164-165 | `ADD ELEMENT stringLiteral addElementClause?` | 去掉 `?`，或注明“ARRAY/TREE 必需、SET 禁止” |
| L168 | `// ADD ELEMENT 后的位置子句；SET 组件不需要位置子句` | 改为“ARRAY/TREE 必需，SET 不需要” |
| L218 | “addElementClause 子句只有 ARRAY 和 TREE 需要” | 与实现一致，可保留；建议补一句“省略时报 2410” |
| L244-253 示例 | ARRAY 示例已带 `AFTER` | 可补一个反例：省略位置 → 2410 |

### 2.2 研发自测文档 C-14

> 原文：*“ARRAY 添加元素时省略位置子句 —— 向 c_arr_new 执行 ADD ELEMENT 'X'，不写 BEFORE/AFTER”*，期望“默认追加到末尾”。

建议改为**负向用例**：

| Case | 步骤 | 预期 |
|---|---|---|
| C-14 | ARRAY / TREE 分别执行 `ADD ELEMENT 'X'`（不写位置子句） | 返回 **2410**（ARRAY 缺 ArrayElementClause / TREE 缺 TreeElementClause）；SET 同语句应成功 |

### 2.3 用户手册

建议在 `ALTER SECURITY LABEL COMPONENT` 一节明确：

- ARRAY：必须 `BEFORE` / `AFTER`；
- TREE：必须 `UNDER`（可附 `OVER` 指定同级顺序），不能单独用 `OVER`；
- SET：不接受位置子句。

## 三、影响

| 项 | 说明 |
|---|---|
| 功能影响 | 无（带位置子句一切正常，安全语义不受影响） |
| 测试影响 | 自测 C-14 若按“默认追加”执行会失败，需改为负向断言 |
| 用户影响 | 按旧语法写会得到 2410，错误信息已能明确指路（`requires an ArrayElementClause` / `TreeElementClause`） |

## 四、我方用例状态

| 用例 | 断言 |
|---|---|
| LB-164 | ARRAY 省略位置 → 2410；ARRAY 带 `AFTER` → 成功；SET 省略 → 成功；**新增** TREE 省略 → 2410、TREE 带 `UNDER` → 成功 |

## 五、证据

- ARRAY：`/tmp/schema_probe.sh`（2026-11-17，普通模式）→ `2410: ARRAY component 'zz_arr' requires an ArrayElementClause`；
- TREE：`/tmp/tree_omission_probe.sh`（2026-11-17，三权分立，security_admin）→ `2410: TREE component 'om_tree' requires a TreeElementClause`；`OVER` 单独使用 → 700；
- SET：同一探针 → 成功；
- 需求原文：`lbac_req.md` L164-165 / L168 / L174 / L218 / L244-253 / L380。
