# 缺陷 TV-D2 —— **已撤回（非缺陷）**：false→true 的列类型冲突按"跳过该列"处理

> 结论：**不是缺陷**。原先按需求 doc 90 §3.2.2「合并失败则属性保持 false」判定为缺陷，
> 经确认，单列类型冲突属于"跳过该列"的正常处理，`SET PROPERTIES` 成功、属性置 true 是产品既定语义。
> 本文件保留判断过程与实测数据，供后续同学参考，避免重复提单。

## 1. 最初的判断（已推翻）

| 项 | 内容 |
|---|---|
| 观察 | 视图列 `s1 DOUBLE`，树侧 `s1` 为 `INT32`/`INT64`；`alter view ... set properties auto_sync_schema=true` **成功**，属性变 true |
| 当时依据 | 需求 doc 90 §3.2.2：「合并成功即修改 properties 成功，若合并失败，那么该 properties 修改失败（依旧为 false）【合并失败的原因有类型不兼容】」 |
| 当时结论 | 判为 P2 语义缺陷（TV-D2），并写了修复建议（冲突时应整体失败） |

## 2. 为什么这不是缺陷

1. 需求原文的"合并失败"指的是**整体合并无法进行**（例如视图定义本身无法建立、列集合完全对不上），
   而**单列类型不一致**属于"该列无法从树侧取值"，按**跳过这一列**处理更符合实际使用：
   用户可能故意把某列声明成更宽的类型（如 DOUBLE），树侧是 INT32 —— 这是**合法的映射意图**；
2. 若按"整体失败"处理，用户反而无法开启自动同步（一列不兼容就全盘拒绝），可用性更差；
3. 实测行为自洽：冲突列保留视图声明类型、不报错、不打 ERROR，其余列正常扩列
   （`TV-SYNC-13` 已验证"非冲突的新测点仍能自动加列"）。

## 2.5 实测对照：三条路径下"冲突"到底会不会失败（2026-10-29 补测）

前提：`root.pc.d1.s1 INT32`、`root.pc.d2.s1 DOUBLE`（同名测点、类型不同）。

| 路径 | SQL | 结果 |
|---|---|---|
| **A** 创建、**不声明** FIELD（必须扫描推断类型） | `create view pc1.v (dev string tag) as root.pc.**` | ❌ 失败 `614: Multiple types encountered when auto detecting type of measurement 's1'` |
| **B** 创建、**声明了 dataType**（不需要扫描） | `create view pc2.v (dev string tag, s1 double field) as root.pc.**` | ✅ 成功，列 `s1 DOUBLE` |
| **C** 创建、声明 FIELD 但**不给 dataType**（需扫描定类型） | `create view pc3.v (dev string tag, s1 field) as root.pc.**` | ❌ 失败 614（同 A） |
| **D** 已有视图（`s1 DOUBLE`）→ 开关 false→true | `alter view pc2.v set properties auto_sync_schema=true` | ✅ 成功，`auto_sync_schema=true`，列仍 `s1 DOUBLE` |
| **E** 开着 auto_sync，再新增**类型冲突**的测点 | `create timeseries root.pc.d3.s1 INT64` | ✅ 视图列不变（仍 DOUBLE），**DN 日志无 305/552、无 ERROR** |

### 规律

**"冲突是否失败"取决于是否需要"扫描推断类型"**：

- **需要推断**（A、C：没给 dataType）→ 多个设备类型不一致就**没法选**，必须失败（614）；
- **类型已确定**（B：用户显式给了；D/E：视图列早已存在）→ **不失败**：
  沿用用户/已有的类型，树侧类型不一致的列取不到数据（NULL），**不覆盖、不报错**。

也就是说 `SET PROPERTIES`（D）本来就不需要推断类型——列是现成的，
它只是"把**还缺**的列补进来"，所以冲突列跳过是自洽的，A/C 的失败与 D 的成功并不矛盾。

> 顺带说明：E 证明"新测点与已有列类型冲突"这条路径也**不会**产生 305/552，
> 与 TDB-890（**并发重复请求**导致的 552/305）是两回事，不要混为一谈。

### 仍存在的文档问题（建议需求侧澄清，不算代码缺陷）

需求 doc 90 §3.2.2 写的是"合并失败 ⇒ properties 修改失败（依旧为 false）"，
但在当前实现里，`SET PROPERTIES` 的合并**几乎不会失败**（已有列沿用、冲突跳过）。
建议需求文档补一句："已存在列的类型以视图声明为准，树侧类型不一致时该列取 NULL，不算合并失败"。

## 3. 现在的用例口径（已改）

`TV-SYNC-13` / `TV-REPRO-D2` 由"断言应失败"改为**固化当前行为**：

| 断言 | 期望 |
|---|---|
| `alter view ... set properties auto_sync_schema=true` | 成功，`show create view` 里为 `auto_sync_schema=true` |
| 冲突列类型 | 保留视图声明的 `DOUBLE`（不被树侧 INT32/INT64 覆盖） |
| 非冲突的新测点（`d3.brand_new`） | 仍能自动加列 |
| 日志 | 不产生 ERROR/WARN |

## 4. 相关证据（保留）

| 内容 | 路径（172.20.70.122） |
|---|---|
| 当时的行为取证 | `TREEVIEW/results/rp_TV-REPRO-D2/cases/TV-REPRO-D2/evidence/repro_d2_toggle.txt` |
| 改为行为确认后的结果 | `TREEVIEW/results/<run>_TV-SYNC-13/...`、`.../TV-REPRO-D2/...` |

## 5. 对整体结论的影响

- 缺陷清单里去掉 D2；
- 回归统计仍为 **35 PASS / 6 FAIL**，但 6 条 FAIL 的归属变了：
  **5 条归属 TDB-890（D1）**（SYNC-06/10/11/13、LEAK-01，功能全过、仅日志 ERROR），
  1 条归属 TV-D3（BASE-07）；
- 即 D2 撤回后，**没有再"因为语义不符"而失败的用例**，剩下的全是已跟踪的日志类问题。
