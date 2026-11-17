# 缺陷草稿 1：ARRAY 组件 `ADD ELEMENT` 省略位置子句被拒（实测 2410），与自测文档期望不一致

> 状态：**草稿，待确认后再提 PLM**（未提交）

## 基本信息

| 项 | 值 |
|---|---|
| 产品 | TimechoDB |
| 版本 | V2.0.13.1 RC2，BuildInfo `83183d0` |
| 环境 | 3C5D（3 CN + 5 DN），Schema 3 副本 / Data 2 副本，IoTConsensus V1 |
| 模块 | 安全 - LBAC - 安全标签组件（Component） |
| 严重程度（建议） | 低（语法易用性 / 文档与实现不一致） |
| 类型 | 功能缺陷 or 文档缺陷（需研发判定） |
| 关联用例 | LBAC 套件 LB-164（自测文档 C-14） |

## 复现步骤

```sql
-- 1. 创建 ARRAY 组件
CREATE SECURITY LABEL COMPONENT zz_arr ARRAY ('A','B');

-- 2. 追加元素，不写 BEFORE / AFTER 位置子句
ALTER SECURITY LABEL COMPONENT zz_arr ADD ELEMENT 'C';
```

## 预期结果（依据研发自测文档 C-14）

> C-14：*“ARRAY 添加元素时省略位置子句 —— 向 c_arr_new 执行 ADD ELEMENT 'X'，不写 BEFORE/AFTER”*，按文档语义应**默认追加到末尾**。

## 实际结果

```
Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 2410: ARRAY component 'zz_arr' requires an ArrayElementClause
```

必须写成 `ADD ELEMENT 'C' AFTER 'B'` 才能成功：

```sql
ALTER SECURITY LABEL COMPONENT zz_arr ADD ELEMENT 'C' AFTER 'B';   -- 成功
```

对比：**SET 组件允许省略位置子句**（`ALTER SECURITY LABEL COMPONENT zz_set ADD ELEMENT 'C'` 执行成功），只有 ARRAY 强制要求。

## 影响

- 按自测文档执行会失败，测试/用户按文档操作会误判为功能异常；
- 与 SET 的行为不一致，容易造成使用困惑；
- 不影响安全语义（带位置子句可正常追加）。

## 建议

| 方案 | 说明 |
|---|---|
| A（推荐） | 与文档对齐：ARRAY 省略位置子句时默认追加到末尾（与 SET 一致） |
| B | 若设计上必须显式指定位置，则更新自测文档与用户手册，并在错误信息里给出正确示例 |

## 证据

- 用例：`lbac_skill` LB-164，2026-11-17 普通模式全量回归 **PASS**（已按“实测被拒”断言，并标注文档差异）；
- 探针记录：`/tmp/schema_probe.sh`（2026-11-17 09:2x 执行），返回 `2410: ARRAY component 'zz_arr' requires an ArrayElementClause`。
