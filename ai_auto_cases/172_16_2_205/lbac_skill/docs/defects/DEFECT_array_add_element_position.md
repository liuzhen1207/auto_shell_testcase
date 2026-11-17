# 缺陷草稿 1（修订）：ARRAY `ADD ELEMENT` 位置子句——需求语法写“可选”、正文写“必需”、自测用例期望“默认追加”

> 状态：**草稿，待确认后再提 PLM**（未提交）
> 结论倾向：**文档不一致**（需求语法 vs 需求正文 vs 自测文档），实现行为与需求正文一致；建议统一文档，或按增强支持省略。

## 基本信息

| 项 | 值 |
|---|---|
| 产品 | TimechoDB |
| 版本 | V2.0.13.1 RC2，BuildInfo `83183d0` |
| 环境 | 3C5D（3 CN + 5 DN），Schema 3 副本 / Data 2 副本，IoTConsensus V1 |
| 模块 | 安全 - LBAC - 安全标签组件（Component） |
| 严重程度（建议） | 低（文档一致性 / 易用性） |
| 类型 | 文档缺陷（主）＋ 可选功能增强（次） |
| 关联 | 需求文档 LBAC（PingCode）；研发自测 C-14；我方用例 LB-164 |

## 需求文档原文（PingCode / LBAC）

| 位置 | 原文 |
|---|---|
| L164-165 | `ALTER SECURITY LABEL COMPONENT identifier` / `ADD ELEMENT stringLiteral addElementClause?` |
| L168 | `// ADD ELEMENT 后的位置子句；SET 组件不需要位置子句` |
| L174 | `// 新增 ARRAY 元素时，用于指定新元素在有序数组中的位置` |
| **L218** | **“addElementClause 子句只有 ARRAY 和 TREE 需要，用于指定添加位置，SET 不需要”** |
| L244-253 | ARRAY 示例 `ADD ELEMENT 'CONFIDENTIAL' AFTER 'SECRET'`；SET 示例 `ADD ELEMENT 'OPS'`（无位置） |
| L380 | “修改组件时，不改变组件类型本身；当前修改语义主要指向已有组件中新增元素，并按组件类型指定插入位置或父子关系。” |

**矛盾点**：语法定义用 `addElementClause?`（`?` = 可选），正文 L218 又说 ARRAY/TREE **需要**位置子句。

## 自测文档期望

> C-14：*“ARRAY 添加元素时省略位置子句 —— 向 c_arr_new 执行 ADD ELEMENT 'X'，不写 BEFORE/AFTER”*，即**默认追加到末尾**。

## 实测（RC2 `83183d0`，普通模式）

```sql
CREATE SECURITY LABEL COMPONENT zz_arr ARRAY ('A','B');
ALTER SECURITY LABEL COMPONENT zz_arr ADD ELEMENT 'C';
-- 2410: ARRAY component 'zz_arr' requires an ArrayElementClause

ALTER SECURITY LABEL COMPONENT zz_arr ADD ELEMENT 'C' AFTER 'B';   -- 成功
```

| 组件类型 | 省略位置子句 | 与需求正文 L218 | 与需求语法 L164 | 与自测 C-14 |
|---|---|---|---|---|
| ARRAY | **被拒（2410）** | 一致（需要位置） | 不一致（语法写可选） | 不一致（期望默认追加） |
| SET | 允许 | 一致（不需要） | 一致 | — |
| TREE | 待补测（当前集群处于三权分立轮次，root 不可登录；跑完补测） | 正文说需要 | 语法写可选 | — |

## 影响

1. 按自测文档 C-14 执行会失败，测试/用户可能误判为功能异常；
2. 需求文档内部（语法定义 vs 正文）不一致，开发/测试各自按不同段落实现与验收；
3. 不影响安全语义（带位置子句时功能正常）。

## 建议（择一，需产品/研发定调）

| 方案 | 说明 |
|---|---|
| **A：按正文统一文档（最小改动）** | 明确“ARRAY / TREE 的 `addElementClause` 为必需”，修正需求语法定义（去掉 `?`）、修正自测 C-14（改为“省略应报 2410”），并在错误信息中给出示例 |
| **B：按语法/自测实现（增强）** | ARRAY 省略位置子句时默认追加到末尾（与 SET 一致的易用性），同步实现与自测文档 |
| C：仅补文档说明 | 保持实现不变，在用户手册写明“ARRAY 必须指定 BEFORE/AFTER”，自测 C-14 同步修正 |

## 证据

- 探针：`/tmp/schema_probe.sh`（2026-11-17 上午，普通模式）返回 `2410: ARRAY component 'zz_arr' requires an ArrayElementClause`；
- 我方用例 LB-164 已按实测断言（ARRAY 省略 → 2410；带 `AFTER` → 成功；SET 省略 → 成功），2026-11-17 普通模式 197 条回归 PASS；
- 需求原文取自 PingCode LBAC 需求页缓存 `lbac_req.md`（L164-165 / L168 / L174 / L218 / L244-253 / L380）。
