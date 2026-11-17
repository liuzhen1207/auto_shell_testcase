# 缺陷草稿 2：SET / TREE 组件不支持多值安全标签（无任何可用语法），与自测文档期望不一致

> 状态：**草稿，待确认后再提 PLM**（未提交）

## 基本信息

| 项 | 值 |
|---|---|
| 产品 | TimechoDB |
| 版本 | V2.0.13.1 RC2，BuildInfo `83183d0` |
| 环境 | 3C5D（3 CN + 5 DN），Schema 3 副本 / Data 2 副本，IoTConsensus V1 |
| 模块 | 安全 - LBAC - 安全标签（Label） |
| 严重程度（建议） | 中（能力缺失：SET/TREE 的多值标签无法创建，相关比较语义无法表达） |
| 类型 | 功能缺陷 or 文档缺陷（需研发判定） |
| 关联用例 | LB-196 / LB-197（自测文档 L-03、L-05、R-09、R-10） |

## 背景

研发自测文档要求：

- L-03：*“SET 使用多个独立字面量 `'RD'`、`'QA'` 创建 p_set.l_set_multi”*；
- L-05：*“TREE 标签使用多值 Development、Software 创建 p_tree.l_tree_multi”*；
- R-09 / R-10：基于上述多值标签做读/写判定（如列由 TREE 多值 `Publishing、Sales` 保护）。

## 复现步骤与实测（三种可能写法全部失败）

准备：

```sql
CREATE SECURITY LABEL COMPONENT pr_dept SET ('RD','QA','FIN');
CREATE SECURITY LABEL COMPONENT pr_org  TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY', 'STORAGE' UNDER 'RND');
CREATE SECURITY POLICY pr_p COMPONENTS pr_dept, pr_org;
```

| # | 写法 | 结果 |
|---|---|---|
| 1 | `CREATE SECURITY LABEL pr_p.l1 COMPONENT pr_dept 'RD' 'QA'` | `700: line 1:55: mismatched input ''QA''. Expecting: ',', <EOF>` |
| 2 | `CREATE SECURITY LABEL pr_p.l1 COMPONENT pr_dept ('RD','QA')` | `700: line 1:49: mismatched input '('. Expecting: <string>` |
| 3 | `CREATE SECURITY LABEL pr_p.l1 COMPONENT pr_dept 'RD', COMPONENT pr_dept 'QA'` | `701: Duplicate component 'pr_dept' in security label` |
| 4 | 同样的三种写法换成 TREE 组件 `pr_org` | 与上表一致（700 / 700 / 701） |

单值 + 其余组件留空是可行的（空值语义正常）：

```sql
CREATE SECURITY LABEL pr_p.l4 COMPONENT pr_dept 'RD';    -- 成功，label_value = RD:()
```

## 预期结果

按自测文档，SET / TREE 组件应支持一次给多个元素值（多值标签），并能参与比较语义（SET 覆盖、TREE 多分支）。

## 实际结果

**不存在任何可用语法**创建 SET/TREE 多值标签：空格分隔、括号、重复 COMPONENT 三种写法分别被 700/700/701 拒绝。

## 影响

1. **能力缺失**：SET 的“集合覆盖”和 TREE 的“多分支”语义在标签层无法完整表达（只能用单值标签做部分覆盖）；
2. 自测文档 L-03 / L-05 / R-09 / R-10 四条用例无法执行，已在我方套件中标为 SKIP（LB-196 / LB-197）；
3. 若产品设计确实只支持单值，则**用户手册与自测文档需要同步修正**，否则测试与交付都会按“应支持”来验收。

## 建议

| 方案 | 说明 |
|---|---|
| A（若设计支持） | 补齐 SET/TREE 多值标签语法（例如 `COMPONENT c 'A','B'` 需与组件分隔符消歧，可考虑 `COMPONENT c ('A','B')`），并补对应解析与校验 |
| B（若设计不支持） | 更新用户手册 + 自测文档，明确“多值仅 ARRAY 不支持 / SET、TREE 仅单值”，并把 L-03/L-05/R-09/R-10 改为负向用例（断言被拒绝） |

## 证据

- 探针：`/tmp/gap_syntax_probe.sh`、`/tmp/gap_syntax_probe2.sh`（2026-11-17 上午），输出如上表；
- 我方用例：`LB-196`（TREE 多值读写）、`LB-197`（SET/TREE 多值创建）当前 SKIP，原因已写入 `cases/c12_gaps.sh` 的 `SKIP_OF`；
- 全量回归：2026-11-17 普通模式 197 条中 185 PASS / 0 FAIL / 12 SKIP（含上述 2 条）。

---

## 附：顺带发现的一个小问题（建议一并确认，不单独提缺陷）

`GRANT EXEMPTION ON RULE ALL` 在 **只含 ARRAY 组件**的策略上展开为 **3 行**：

```
grantee |     rule_name |access_type|ordinal
  ex_u1 |LBACWRITEARRAY |      WRITE|      1
  ex_u1 |LBACWRITEARRAY |      WRITE|      1     ← 两条完全相同
  ex_u1 | LBACREADARRAY |       READ|      1
```

两条 `LBACWRITEARRAY` 的 rule_name / access_type / ordinal 完全一致（推测是 WRITE_UP 与 WRITE_DOWN 共用一行、未落方向字段）。请研发确认：是设计上不区分方向，还是漏了方向字段/去重。
