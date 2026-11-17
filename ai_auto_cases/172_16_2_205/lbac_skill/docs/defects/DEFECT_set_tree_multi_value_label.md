# 缺陷草稿 2（已撤回）：SET / TREE 多值标签——实际支持，此前探针写法错误

> 状态：**已撤回，不提 PLM**（2026-11-17 复核后作废）
> 结论：多值语法**是支持的**，正确写法为需求文档 L634 示例：`COMPONENT dept 'RD', 'QA'`。
> 保留本文仅作为“语法易混淆”的记录，供文档/手册改进参考。

## 撤回原因

初版草稿依据以下三种写法失败，判定“不支持多值”：

| # | 当初尝试的写法 | 结果 |
|---|---|---|
| 1 | `COMPONENT pr_dept 'RD' 'QA'`（空格分隔） | 700 语法错误 |
| 2 | `COMPONENT pr_dept ('RD','QA')`（括号包裹） | 700 语法错误 |
| 3 | `COMPONENT pr_dept 'RD', COMPONENT pr_dept 'QA'`（重复 COMPONENT） | 701 Duplicate component |

**但这三种都不是需求规定的写法。** 需求文档 L634-638 的示例是：

```sql
-- 一个 component 指定多个值用 ',' 衔接
CREATE SECURITY LABEL data_policy.public_rd_qa
  COMPONENT level 'PUBLIC',
  COMPONENT department 'RD', 'QA',
  COMPONENT org 'RND';
```

即：**同一个 COMPONENT 关键字后，用逗号分隔多个值**（逗号后直接跟字符串，不再写 COMPONENT）。

## 实测（RC2 `83183d0`，2026-11-17 复核）

```sql
CREATE SECURITY LABEL COMPONENT mv_dept SET ('RD','QA','FIN');
CREATE SECURITY LABEL COMPONENT mv_org  TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY', 'STORAGE' UNDER 'RND');
CREATE SECURITY POLICY mv_p COMPONENTS mv_lvl, mv_dept, mv_org;

-- A) 需求示例写法
CREATE SECURITY LABEL mv_p.l_multi COMPONENT mv_dept 'RD', 'QA';            -- 成功
-- B) 多值 + 其它组件
CREATE SECURITY LABEL mv_p.l_mix   COMPONENT mv_dept 'RD', 'QA', COMPONENT mv_org 'RND';   -- 成功
-- C) TREE 多值
CREATE SECURITY LABEL mv_p.l_tree  COMPONENT mv_org 'RND', 'STORAGE';      -- 成功
```

查询 `information_schema.security_labels`：

```
| policy | label_name |      label_value |
|   mv_p |    l_multi |  ():(QA,RD):()    |
|   mv_p |      l_mix |  ():(QA,RD):RND   |
|   mv_p |    l_tree  |  ():():(RND,STORAGE) |
```

## 遗留的文档/易用性问题（建议改进，不构成缺陷）

1. **多值与组件分隔符都用逗号**，极易混淆：
   - 组件之间：`COMPONENT c1 'A', COMPONENT c2 'B'`
   - 组件内多值：`COMPONENT c1 'A', 'B'`
   - 建议在用户手册/自测文档里并排给出两组示例，并明确“逗号后是否出现 COMPONENT 关键字”是区别点。
2. **多值 `label_value` 的展示顺序被规范化**：输入 `'RD','QA'`，展示为 `(QA,RD)`（看起来按字典序重排）。需求 L1855 只规定“同一 Component 多个值写作 `(v1,v2)`”，未说明是否保序/排序规则，建议明确。
3. 括号写法 `('RD','QA')` 会被报语法错误，与需求 L776“使用括号包裹，并用逗号分隔，例如 `(RD,QA)`”的表述**容易让人误以为是 SQL 写法**（实际那是 `label_value` 的展示格式）。建议在需求/手册中区分“SQL 输入写法”与“展示格式”。

## 我方用例的调整

- LB-196（SET 多值读写语义）、LB-197（TREE 多值读写语义）已从 SKIP 改为**真实用例**，使用需求规定写法；
- 原 `docs/selftest_coverage.md` 中“语法不支持”的结论已更正。
