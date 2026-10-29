# 【已关闭 · 符合预期】`auto_sync_schema` 列类型冲突的处理口径

> **研发确认结论（2026-10-29）**：
> **只有「创建视图」时才会因列类型冲突等原因返回失败；其它路径（`SET PROPERTIES` 开关切换、
> 自动加列）默认忽略冲突。** 即本文 A/B/C 三条描述正确，D/E 的行为**符合设计预期**。
>
> 因此：**本项不作为缺陷**，测试侧按"行为基线"固化；原 TV-D2 彻底关闭。
>
> 状态：**已关闭（符合预期）**
> 版本：`master_1026_dc11a35`（2.0.11-SNAPSHOT，BuildInfo `dc11a35`）
> 环境：5 CN + 20 DN，SchemaRegion 3 副本 / DataRegion 3 副本，`IoTConsensus`
> 相关需求：PLM doc 90《V2.0.13.1-树转表视图自动检测新增测点-需求分析》§3.2.2

## 0. 研发结论与遗留问题

**已确认**：仅创建路径校验类型冲突（A/C 失败 614、B 成功），其余路径（D 开关切换、E 新增冲突测点）
一律**默认忽略**——符合预期。

**遗留（文档，不影响功能）**：doc 90 §3.2.2 仍写着「合并失败 ⇒ properties 保持 false【类型不兼容】」，
与上述口径不一致，建议需求文档补一句「**仅创建时校验类型冲突；其余路径忽略**」，
否则后续测试仍会按文档再报一次。

**建议（可选，不阻塞）**：冲突列被跳过时给一条 debug/info 日志，便于现场自查"某列为什么没数据"。

---

## 0.1 原始确认清单（已答复，保留备查）

| # | 问题 | 我们的理解 |
|---|---|---|
| **Q1** | `SET PROPERTIES auto_sync_schema=true` 时，若视图已有列的类型与树侧同名测点**不一致**，**应该**「整体失败并保持 false」（doc 90 原文），还是**应该**「跳过该列、属性照常置 true」？ | 实现是后者；文档是前者 |
| **Q2** | 如果是「跳过该列」，这种**部分生效**是否需要**留下日志/可发现性**（WARN 带列名+两侧类型，或 `show create view` 标注）？ | 目前**完全静默**：CN/DN 均无任何日志 |
| **Q3** | 若确认「跳过即设计」，是否可以**同步修改 doc 90 §3.2.2** 的表述（否则测试会按文档判失败）？ | 需要文档给出结论，用例才能定稿 |

## 1. 现象（一句话）

对**已有视图**（列 `s1 DOUBLE`）执行 `alter view ... set properties auto_sync_schema=true`，
而树侧同名测点 `s1` 是 `INT32`/`INT64`：

```
SQL> alter view pc2.v set properties auto_sync_schema=true
Msg: The statement is executed successfully.          ← 成功，不报错

SQL> show create view pc2.v
CREATE VIEW "v" ("time" TIMESTAMP TIME,"dev" STRING TAG,"s1" DOUBLE FIELD)
  WITH (ttl='INF', auto_sync_schema=true) ...          ← 属性已置 true

SQL> desc pc2.v
s1  DOUBLE  FIELD                                      ← 冲突列仍是 DOUBLE（未被覆盖）
```

结果：属性已开、无任何报错、**该列永远取不到树侧数据（恒 NULL）**，且**没有任何日志提示**。

## 2. 复现步骤（可直接照做）

```sql
-- 树模型：同名测点 s1 在两个设备上类型不同
create timeseries root.pc.d1.s1 INT32;
create timeseries root.pc.d2.s1 DOUBLE;

-- 表模型：视图把 s1 显式声明成 DOUBLE
create database pc2;
create view pc2.v (dev string tag, s1 double field) as root.pc.**;

-- 触发点
alter view pc2.v set properties auto_sync_schema=true;   -- 期望？实际：成功
show create view pc2.v;                                   -- auto_sync_schema=true
desc pc2.v;                                               -- s1 仍为 DOUBLE
```

## 3. 需求原文 vs 实现

**需求（doc 90 §3.2.2「异常情况说明」）**：

> 当从 false 改为 true 的时候，会需要去扫描 prefixPath 下面符合要求的序列，然后和视图中已有的列进行合并，
> 合并成功即修改 properties 成功，**若合并失败，那么该 properties 修改失败（依旧为 false）
> 【合并失败的原因有类型不兼容】**

**实现**：`iotdb-core/confignode/src/main/java/org/apache/iotdb/confignode/persistence/schema/TreeDeviceViewFieldDetector.java`

```java
// 创建路径 :83-96 —— tolerateTypeMismatch = false（冲突就失败）
public TSStatus detectFieldsForCreation() {
    new TreeDeviceViewFieldDetectionTaskExecutor(..., null, false)

// 合并路径 :122-131 —— tolerateTypeMismatch = true（冲突被吞掉）
public Pair<TSStatus, List<TsTableColumnSchema>> detectNewFieldColumnsAfterCreation() {
    new TreeDeviceViewFieldDetectionTaskExecutor(..., null, true)
```

> 说明：`detectNewFieldColumnsAfterCreation()` 只做「补**缺**的列」，并不新建已存在的列；
> 因此该参数在这里的实际效果就是**抑制 `DATA_TYPE_MISMATCH` 报错**。

## 4. 实测对照：什么时候会失败、什么时候不会

前提同上（`d1.s1 INT32` + `d2.s1 DOUBLE`）：

| 路径 | SQL | 实际结果 |
|---|---|---|
| **A** 创建、不声明 FIELD（必须扫描推断） | `create view v (dev string tag) as root.pc.**` | ❌ **失败** `614: Multiple types encountered...` |
| **B** 创建、声明了 dataType（无需扫描） | `create view v (dev string tag, s1 double field) as ...` | ✅ 成功，`s1 DOUBLE` |
| **C** 创建、声明 FIELD 但不给 dataType | `create view v (dev string tag, s1 field) as ...` | ❌ **失败 614**（同 A） |
| **D** 已有视图（`s1 DOUBLE`）→ 开关 false→true | `alter view ... set properties auto_sync_schema=true` | ✅ 成功、属性 true、列仍 DOUBLE |
| **E** 开着 auto_sync，再新增类型冲突测点 | `create timeseries root.pc.d3.s1 INT64` | ✅ 列不变，**无 305/552、无 ERROR** |

**规律**：冲突是否失败，取决于**是否需要"扫描推断类型"**——

- 需要推断（A、C）→ 多个设备类型不一致，无法选择 ⇒ 必须失败（614）；
- 类型已确定（B 用户显式指定 / D、E 列已存在）⇒ 不失败，沿用已有类型，冲突列取 NULL。

所以 **A/C 失败 与 D 成功并不矛盾**，这也是我们最初判"不是功能 bug"的原因。

## 5. 为什么我们仍建议记录（三条理由）

1. **与需求文本直接冲突**：文档逐字点了"类型不兼容"是合并失败原因，而代码在该路径把它关掉了；
   测试的验收依据是需求文档，因此至少需要产品/研发给出口径。
2. **用户视角不对称**：B 场景用户**主动声明**了类型（心里有数）；D 场景用户只是**点了个开关**，
   此刻没有声明任何类型，而需求对这条路径的承诺是"合并失败要报错/保持 false"。
   典型踩坑：视图几个月前建的，树侧类型后来迁移过，运维一键开启 auto_sync 以为全列都在同步。
3. **完全静默（可观测性缺失）**：冲突列被跳过时，CN/DN 日志**一条都没有**
   （按 `pc2` / `type.?mismatch` / `skip` / `tolerat` 全量 grep 均无命中），
   用户看到 `auto_sync_schema=true` 且无报错，无法发现"某一列其实没同步"。

## 6. 两种处置方案（请选一个）

| 方案 | 内容 | 我们的评估 |
|---|---|---|
| **方案 1：保持现实现，改文档** | doc 90 §3.2.2 补充："已存在列的类型以视图声明为准；树侧类型不一致时该列取 NULL，**不算合并失败**" | 改动最小；建议同时在第 2 条里给个可发现性（哪怕一条 WARN） |
| **方案 2：保持文档，改实现** | 合并时逐列比对类型，不一致 ⇒ `SET PROPERTIES` 整体失败、属性保持 false | 与文档一致，但一列不兼容就挡住整个功能，可用性变差（TDB-890 也说明该路径容易踩） |
| **折中（我们推荐）** | 不改失败语义，但把被跳过的冲突列打 **WARN**（列名 + 视图类型 + 树侧类型），或 `show create view` 标注"未参与同步" | 成本最低、可发现性到位 |

## 7. 我们这边的处理状态

- 该问题**未提交 PLM**，在测试技能包里标记为「**待确认**」，不是已确认缺陷；
- 已把对应用例改成**行为固化**版（断言"属性成功置 true + 冲突列不被覆盖 + 非冲突列仍能扩列"），
  研发确认后：
  - 若判"设计如此" → 保留行为固化版，并更新需求文档与 `COVERAGE` 矩阵；
  - 若判"应该失败" → 我们把断言改回"应失败且保持 false"，并补一条缺陷单。

## 8. 环境与证据

| 内容 | 位置 |
|---|---|
| 实测脚本（可重跑） | `/data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d/probe_conflict.sh` |
| 用例 | `TV-SYNC-13`（行为固化版）、`TV-REPRO-D2` |
| 取证（SQL + 输出） | `TREEVIEW/treeview_5c20d/results/<run>_TV-SYNC-13/.../actions.log` |
| 撤回说明 + 完整对照表 | `TREEVIEW/reports/DEFECT_TV_D2_WITHDRAWN.md` |
| 源码 | `TreeDeviceViewFieldDetector.java:83-96`（false）、`:122-131`（true）；`:344-360` 类型比对；`ClusterSchemaManager.java:1898-1908`（552 产生处） |
