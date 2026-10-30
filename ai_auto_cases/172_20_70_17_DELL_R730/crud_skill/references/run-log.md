# CRUD skill 运行记录

## 2026-10-06 · 第二轮（8 条 P0 全部 PASS）

- 运行目录：`results/20261006_092842_matrix/`（REPORT.md / summary.tsv / cases/<id>/actions.log）
- 结果：**PASS 8 / SKIP 63 / FAIL 0**（新增 3 条：表模型建表写入回读、表模型时间区间删除、树模型无模式写入+元数据自动创建）

### 执行器改动经验（血泪版，务必遵守）

1. **不要用正则/字符串切分批量改写执行器源码**：含逗号的 SQL 字面量（`f"...(timestamp, s1)..."`）和 TTL 助手会被截断，造成语法损坏、多轮返工。要改就**整段替换或显式重写函数体**。
2. **模块三件套必须齐**：`Ctx` + `CaseSpec` + `CASES = _build_cases()`。基础设施段（导入/数据类/`reset_tree_db` 等助手）直接从 `iotdb-ttl` 的 `ttlkit/ttlcases.py`（首个 `def case_ttl_` 之前的部分）复制；一旦被破坏，用它重新覆盖最省事。
3. **用例函数与注册一律放在文件尾部**，注册用装饰器：
   ```python
   @_impl                      # _IMPL[fn.__name__[5:]] = fn
   def case_crud_xxx(ctx): ...
   ```
   避免 `_IMPL` 前向引用 / 注册循环早于 `_IMPL` 这两类顺序坑（本轮连踩三次）。
4. **断言只用 `ctx.check(bool, msg)`**：`ctx.req(x, msg)` 要求 SQL 结果对象，传行列表会报 `'list' object has no attribute 'ok'`；也不要给 `ctx.check` 传 `ctx.api.run(...)` 的返回值（`SqlOutcome` 不可 JSON 序列化，runner 写 `result.json` 时会 `TypeError`）。
5. **`ctx.api.table()` 返回 `list[dict]`**，行内含 `Time` 列 ⇒ 解析数值要跳过/容错，不能假设第一个单元格就是值。
6. **`create_table`/`insert_table` 等助手返回值类型不统一**（可能是 str）⇒ 不要断言其返回值，用**后续回读**作为判定依据。

## 2026-10-06 · RC5（V2.0.12.1，包 timechodb-2.0.12.1-bin.zip，提交 aaf460d）

- 环境：`DB_DIR=/data/mpp_test/v20121rc5_crud`，3 ConfigNode + 5 DataNode，IoTConsensus，激活通过
- 部署/准备：`scripts/crud.sh --conf conf/crud.rc5.conf deploy|prepare` 成功（8 节点 Running/ReadOnly）
- 运行目录：`results/20261006_091626_matrix/`（REPORT.md / summary.tsv / cases/<id>/actions.log）
- 结果：**PASS 5 / SKIP 66 / FAIL 0**
  - `crud_insert_single_tree` PASS（建库 + 单行写入 + 按时间点回读值一致）
  - `crud_insert_multi_rows` PASS（同设备 5 行写入，回读行数=5）
  - `crud_overwrite_same_ts` PASS（同时间戳写两次 ⇒ 一行，值为后写）
  - `crud_delete_time_range_tree` PASS（写 3 行删 1 行 ⇒ 剩 2 行）
  - `crud_query_time_range` PASS（`[start,end)` 左闭右开：命中 2 行、右端点不含）
- 首轮踩坑（均属**用例实现问题**，已修，记录以免重犯）：
  1. `must` 在 `ctx.api` 上而非 `Ctx` 上；
  2. `TtlApi.must()` 只接 SQL 一个参数，不能传标签；
  3. 断言应用 `ctx.check(bool, msg)`；`ctx.req()` 需要 SQL 结果对象，传行列表会报 `'list' object has no attribute 'ok'`；
  4. SELECT 结果含 `Time` 列，按单元格解析数值时必须跳过表头/时间列。

## 最终覆盖状态（20261006_185105_matrix）

**PASS 53 / SKIP 18 / FAIL 0**（共 71 条）

### 剩余 SKIP 及其原因（均为执行能力缺口，不是产品结论）

- **需要 Session/Tablet 写入通道**（5 条）：`crud_tablet_batch_tree`、`crud_tablet_batch_table`、`crud_insert_empty_batch`、`crud_regr_tdb352_object_write_delete`、`crud_regr_rc5_object_null_npe`
- **需要集群重启/回放能力**（5 条）：`crud_consistency_after_restart`、`crud_consistency_wal_replay`、`crud_schema_auto_create_off`、`crud_timestamp_precision`、`crud_regr_tdb423_multi_precision`
- **需要合并专门触发/参数组合**（2 条）：`crud_compaction_query_equal`、`crud_regr_tdb442_delete_compaction`
- **需要负载（iot-benchmark）或长时观测**（2 条）：`crud_regr_tdb184_query_reserved_size`、`crud_regr_tdb116_remove_region_write`
- **语法/语义待实测确认后再定断言**（2 条）：`crud_query_table_view`、`crud_nan_inf_values`
- **其它**（2 条）：`crud_out_of_order_disabled`、`crud_aligned_mixed`

> 说明：SKIP 一律不计入 PASS；补这些用例需要给 crudkit 增加对应能力（Session/Tablet 通道、集群重启子命令、合并触发、iot-benchmark 挂载），
> 或先实测确认语法后再写断言。


## 最终状态（20261006_202037_matrix）

**PASS 60 / SKIP 11 / FAIL 0**（共 71 条，A 级证据：每条含 SQL 原文与服务端返回）

本轮为三件事新增并真实通过：重启后一致、未 flush 写入经 WAL 回放后一致、树/表模型批量写入、
OBJECT 批式写 NULL 回归（无 NPE）、合并前后查询一致、TDB-442 删除后合并不复活。

### 剩余 11 条 SKIP 的清单

- `crud_timestamp_precision`
- `crud_insert_empty_batch`
- `crud_out_of_order_disabled`
- `crud_aligned_mixed`
- `crud_schema_auto_create_off`
- `crud_nan_inf_values`
- `crud_query_table_view`
- `crud_regr_tdb352_object_write_delete`
- `crud_regr_tdb184_query_reserved_size`
- `crud_regr_tdb423_multi_precision`
- `crud_regr_tdb116_remove_region_write`

原因归纳：① 需要**原生 Session/Tablet API**（CLI 通道只能用多行 VALUES 近似）；② 需要**改 props + 重启的参数组合**
（如 TDB-442 的 `enable_seq/unseq/cross_space_compaction=false`、`inner_compaction_candidate_file_num=2`）；
③ 需要 **iot-benchmark 负载或长时观测**（TDB-352/TDB-184）；④ 语法/语义待实测确认后再定断言（表视图、NaN/Inf 等）。

## skill 注册方式（item 3，已生效）

- 机制：skill 定义在 `<workspace>/.dsh/skills/<name>/`，目录名即 catalog 里的 skill 名，`SKILL.md` 的 YAML frontmatter
  （`name` / `description` / `whenToUse` / `metadata.version` / `metadata.category`）就是 catalog 显示的描述与触发条件。
- 本 skill：`ln -s /data/deepseek/CRUD /home/ubuntu/remove_cn_dn/.dsh/skills/iotdb-crud`，并在 `SKILL.md` 顶部写入了 frontmatter。
- **回滚**：`rm /home/ubuntu/remove_cn_dn/.dsh/skills/iotdb-crud`（软链接，不影响 `/data/deepseek/CRUD` 本体）。
- 验证：会话的 skill catalog 已并列列出 `iotdb-crud`、`iotdb-remove-cn-dn`、`iotdb-ttl`。


## 原生 Session/Tablet 通道探针（tools/tablet_probe/TabletProbe.java）

用本地 JDK17 + 客户端 jar（`tools/tablet_probe/lib_rc5/` 取自远端部署包 `lib/`，与 RC5 严格同版本）
对远端集群跑原生 Session：

| 探针步骤 | 结果 | 说明 |
| --- | --- | --- |
| `Session.open()` | **OK** | 原生 Session 通道可用 |
| 树模型 `insertTablet`（DOUBLE 列） | **OK** | 原生 Tablet 写入可用，这条路可以承载 `crud_tablet_*` |
| 表模型建表（裸 Session） | **ERR 700** | 裸 Session 走 tree 方言，表模型需表方言（或经 kit 的 table dialect 建表） |
| OBJECT 列经 Tablet 写入 | **ERR IllegalArgumentException** | 客户端 tsfile 的 `addValue(int,int,byte[])` 只接受 TEXT/STRING/BLOB；`Tablet` 无 `Binary` 重载 |

**路径区分（重要）**：`IllegalArgumentException: The data type of column index 0 is not TEXT/STRING/BLOB`
是**客户端类型检查**，且该检查不在 IoTDB 源码树内（属 tsfile 依赖）。因此此前在 remove-cn-dn 轮次
观察到的 OBJECT 写 NULL `Binary.getLength()` NPE **不是**普通 Session/Tablet 路径能复现的，
它来自 iot-benchmark 自带的写入路径（未在本 skill 复现，证据等级记为 B/C，不作为产品结论）。

### 编译/运行命令（可复现）

```
cd /data/deepseek/CRUD/tools/tablet_probe
BM=/data/deepseek/benchmark/bm_20260812_e158c2c_jdk17/lib
javac -cp "lib_rc5/*:$BM/*" TabletProbe.java
java  -cp "lib_rc5/*:$BM/*:." TabletProbe 11.101.10.9 6667 root '<password>'
```


## Tablet 通道接入执行器（真实 insertTablet）

`crud_tablet_batch_tree` 已从"多行 VALUES 近似"升级为**真实 Session/Tablet 写入**：用例调用
`tools/tablet_probe/TabletProbe.java`（本地 JDK17 + `tools/tablet_probe/lib_rc5/` 中与 RC5 同版本的客户端 jar），
断言 `TREE_TABLET_OK` 且写入的 3 行能经 SQL 回读。新增 `crud_insert_empty_batch`（0 行 Tablet 不应报错），两条均在 RC5 上 PASS。

- 结论（A 级）：树模型 `insertTablet` 通道可用；空 Tablet 写入不报错。
- 仍为 SKIP：`crud_tablet_batch_table`（表模型 Tablet 需要 `IDeviceID` 形态 + 表方言，裸 Session 默认 tree 方言）。


## 未决问题（表模型 Tablet，勿当结论用）

`crud_tablet_batch_table`（表模型 Tablet）**已退回未实现（SKIP）**，原因两条，都属执行器/用例侧：

1. **表模型设备路径形态不对**：探针用 `IDeviceID.Factory.DEFAULT_FACTORY.create(new String[]{db, table, tag})`
   + `Tablet(IDeviceID, names, types, 3)` 写入时，服务端返回
   `StatementExecutionException: 508: Path does not exist.` —— 说明表模型 Tablet 的 device 形态或建表/写入配合还需实测确认
   （候选：`create(String[])` 的层级、是否需要 `use db`、tag 列名与 measurement 名的对应关系）。
2. **一次假 PASS（重要教训）**：该次运行 CLI 报 `PASS=1`，但 `actions.log` 里只有 `TABLE_TABLET_ERR`、没有 `TABLE_TABLET_OK`，
   `result.json` 的两条 check 却均为真。⇒ 判定链存在我尚未定位的漏洞，**在查清之前不得信任该用例的运行判定**；
   所有结论仍以 `actions.log` 中的服务端原始返回为准。


## 判定链缺陷与修正（重要，已修复）

**缺陷**：`Ctx.check` 的真实签名是 `check(name: str, ok: bool, detail="", evidence="")`，
而 CRUD 用例全程按 `check(条件, 说明)` 调用 ⇒ 条件被当作 `name`、非空说明字符串被当作 `ok`（**恒为真**），
导致断言层恒通过、`PASS` 计数虚高。**修正**：用括号感知的方式把 CRUD 段 82 处 `ctx.check` 的两参数对调
（未触碰 TTL 基础设施），随后全矩阵重跑得到真实判定。

**修正后的真实结果**：44 PASS / 17 FAIL / 11 SKIP（此前显示的 61 PASS 不可信）。
17 条 FAIL 全部是**用例实现侧问题**（断言期望值/类型/载荷写法），不是产品缺陷；判定一律以 `actions.log`
中服务端原始返回为准。

**教训**：派生 kit 时，先核对被调用 API 的**签名顺序**（`check(name, ok)` 与 `check(ok, msg)` 只差顺序，却会让全部断言静默失效），
再用"故意写错一条断言看是否 FAIL"的方式做**判定链自检**，然后才谈覆盖率。


## 17 条 FAIL 的根因分类（全部用例侧，已定位）

1. **表模型裸 SQL 建表后的插入报 `616: Unknown column category for timestamp. Cannot auto create column.`**
   —— 用裸 SQL `create table <db>.<t>(...)` 建表后，用例里的 `insert into <t>(timestamp, ...)` **未加库名限定**，
   语句落到了别的库（该库无此表、自动建列失败）。对照组：用 kit 的 `create_table/insert_table` 辅助函数的
   用例（`crud_insert_single_table`、`crud_delete_time_range_table`）同写法却正常。
   **修法**：表模型语句统一写成 `insert into <db>.<table>(...)` / `select ... from <db>.<table>`（或统一改用 kit 辅助函数）。
2. **树模型显式 NULL 写入被拒**：`INSERT INTO root.crud_a.d1(timestamp, s1) VALUES (ts, null)` 返回
   `507: Fail to insert measurements [s1] ...` ⇒ 这是**实测行为（A 级）**，用例期望写错了，应断言"被拒 + 不产生行"。
3. **未建库写入会静默建库**：`crud_insert_missing_db` 的日志显示 `root.crud_b` 确实被创建（自动建库/schema 生效）
   ⇒ 同样是**实测行为（A 级）**，断言方向要反过来。
4. **取值/排序期望写错**：`crud_overwrite_partial_cols`（按列名取值的解析）、`crud_query_order_desc`
   （降序结果实际为 `[2.0, 1.0, 0.0]`）⇒ 按真实列结构改写解析与期望。
5. 其余"实测 0 行"多由第 1 类连带引起；删除类用例（"实测 3/1"）需按 `actions.log` 核对删除语句形态与时间区间。


## 开放项（需受控复现，勿下结论）：DELETE 后 SELECT 仍返回被删行

**证据（A 级，原始日志）**：`crud_delete_time_range_tree` 在 RC5 上的实际序列为
`CREATE DATABASE root.crud_a` → 3 次 `INSERT INTO root.crud_a.d1(timestamp, s1) VALUES (1700000300000/301000/302000, 0.0/1.0/2.0)`
→ `DELETE FROM root.crud_a.d1 WHERE time <= 1700000300000`（服务端回 `The statement is executed successfully.`）
→ `SELECT s1 FROM root.crud_a.d1` **仍返回 3 行**（含 0.0 那行，`Total line number = 3`）。

**为什么不能直接判定为缺陷**：`time <= X` 的删除语义、是否需要 flush/重启后才生效、是否与查询缓存相关，
都还没排除；同类"删除无效"现象在多条删除用例里同时出现（`crud_delete_keeps_schema` 实测 3、`crud_delete_out_of_order` 实测 2），
也可能是**同一个执行器侧原因**（例如语句经由 CLI 批量执行时的会话/库上下文）。

**最小复现步骤（下一步执行，逐步记录原始返回）**：
1. `CREATE DATABASE root.probe_del`；插入 3 行（t, t+1000, t+2000）；
2. `DELETE FROM root.probe_del.d1 WHERE time = t`；立即 `SELECT`；
3. `FLUSH`；再 `SELECT`；
4. 集群重启；再 `SELECT`；
5. 换 `DELETE FROM root.probe_del.d1 WHERE time <= t` 重做一遍，比较差异。
只有 2–4 步都显示被删数据仍可查，且换形态后依旧如此，才按**产品缺陷**上报（届时补 `show timeseries`/`show devices` 佐证）。

**同时确认**：本轮 18 条 FAIL 中，"表模型回读 0 行"一族仍未修好（库限定改动未收敛，且新增 3 条 FAIL），
下一轮起**一次只改一条用例、只单跑该用例**，不再做批量文本改造。


## 探针结论（crud_probe_delete，A 级，可复现）：删除在该环境完全不可见

`results/20261007_084603_run`（312.8s）逐步记录：

| 步骤 | 动作 | 行数 |
| --- | --- | --- |
| 1 | 插入 3 行（t, t+1000, t+2000） | 3 |
| 2 | `DELETE ... WHERE time = t`（服务端回 executed successfully） | **3** |
| 3 | `FLUSH` | **3** |
| 4 | **集群重启后** | **3** |
| 5 | `DELETE ... WHERE time <= t+1000` | **3** |

⇒ 四种条件下删除都**完全不生效**，且跨重启持久。

**根因未定性（重要）**：可复现 ≠ 已定位。尚未排除的因素（下一步依次排查）：
1. **环境**：DataNode 是否处于磁盘阈值/`ReadOnly` 状态（部署时观察到节点状态含 ReadOnly），只读态可能使删除被静默忽略；
2. **通道/方言**：`ctx.api.run` 的语句是否落在预期的库与会话（`DELETE FROM root.probe_del.d1` 的路径解析）；
3. **对照**：用 `DELETE DEVICES` / `delete timeseries` / 表模型 `delete from` 等不同形态各做一次；
4. **佐证**：`show timeseries`、`show devices`、DN 日志里的 delete/mod 记录。

**在此之前不按产品缺陷上报**。另注：此前多轮"删除类用例 PASS"是断言恒真的假 PASS，掩盖了该现象，这也是本轮才暴露出来的原因。


## 数据库语法事实（A 级，来自 RC5 源码测试 + 真机实测）

本轮把"回读 0 行"这一族查清，全部是**用例写法**问题，三条语法事实如下（均已真机验证）：

| 事实 | 错误写法 → 服务端返回 | 正确写法 | 依据 |
| --- | --- | --- | --- |
| 表模型的时间列名 | `insert into t(time?)` 用 `timestamp` ⇒ `616: Unknown column category for timestamp. Cannot auto create column.` | **`time`**（或直接用 kit 的 `insert_table`，它生成的就是 `time`） | 实测 + kit 辅助函数对照 |
| **OBJECT 列的字面量** | 裸字符串 `'abc'` ⇒ `507: Fail to insert measurements [obj] caused by [data type is not consistent, input abc, registered OBJECT]`；`cast('abc' as OBJECT)` ⇒ `701: Unsupported expression` | **`to_object(true, 0, X'616263')`**；注意裸 `X'..'` 对应的是 **BLOB** 列 | RC5 源码测试用例 `INSERT INTO t1(time, device_id, b1, o1, ...) VALUES(1, 'd1', X'cafebabe01', to_object(true, 0, X'cafebabe01'), ...)` |
| 删除的路径形态 | `DELETE FROM root.db.d1 WHERE time = t`（设备路径不带通配符）⇒ **静默成功但无效果**（行数不变，跨 flush/重启仍不变） | **`DELETE FROM root.db.d1.** WHERE time = t`**（`.**` 命中时序） | 对照探针：`.**` 形态 3→1 生效，`DELETE TIMESERIES root.db.d1.s1` 生效，`DELETE DEVICES <path>` 在本版本报 `700` 语法错误 |

**对"删除失效"假设的结论**：证伪——删除功能正常，是我写的路径形态不对（且失败时**静默返回成功**，这点值得作为易用性问题记录，不作为缺陷上报）。

**OBJECT 写 NULL 的补充证据**：表模型 `insert ... values (time, 'd1', null)` 可成功落库（`crud_insert_null_object_table` PASS），
说明 NULL 走 SQL 路径无 NPE；Tablet 路径此前已被客户端类型检查挡住（见上文），两条路径的差异保持区分。


## 表模型 Tablet：三种 device 形态均报 508（能力/用法限制，非产品结论）

在 RC5 上用 `crud_tablet_batch_table`（表由 kit 用表方言建好，探针只做写入）依次尝试
`IDeviceID.Factory.DEFAULT_FACTORY.create(...)` 的三种形态，全部失败：

| 形态 | 结果 |
| --- | --- |
| `create(new String[]{db, table, tag})` | `StatementExecutionException: 508: Path does not exist.` |
| `create("db.table.tag")` | 同上 |
| `create(new String[]{table, tag})` | 同上 |

⇒ 裸 `Session` 写表模型 Tablet 还缺一个未知环节（候选：会话需要表方言/先 `use <db>`、
measurement 列表需含 tag、或必须走 `ISessionPool` 的表接口）。该用例保持 **SKIP**，
不计入 PASS；未在 IoTDB 源码树中找到反证，故**不按产品缺陷上报**，属本执行器尚未打通的能力缺口。

**已打通的 Tablet 能力（A 级）**：树模型 `insertTablet`、空 Tablet（0 行）写入；OBJECT 列经 Tablet 被客户端类型检查拒绝（见前文）。


### 追加尝试：`.sqlDialect("table")` 仍然 508

在探针上按 `Session$Builder.sqlDialect(java.lang.String)` 传入 `table` 后重跑，三种 device 形态依旧全部
`508: Path does not exist.` ⇒ 裸 Session + `insertTablet` 写表模型这条路，本执行器**尚未打通**。
已知可用的是：树模型 Tablet、空 Tablet（A 级）；表模型 Tablet 需要研发确认正确的 `IDeviceID`/会话约定。


### 追加：按用户提示（先 use db、measurement 含 tag）仍不通；改走 benchmark 表模型写入路径

按提示把探针改为 `use <db>` + measurement 列表含 tag 列（`devid`），并把 device 候选扩到 6 种
（`[db,table,tag]`、`"db.table.tag"`、`[table,tag]`、`"db.table.tag."`、`[db.table, tag]`、`"table.tag"`），
全部返回 `508: Path does not exist.`；`USED_DB=usr_crud_tabt` 说明 `use` 本身成功。
⇒ 裸 Session + `insertTablet` 的表模型写入在本执行器不可达，**改为按用户指示用 iot-benchmark 的表模型写入路径覆盖**
（benchmark 的 `iotdb-2.0` 模块本身就写表模型数据，是官方负载路径）。


## crud_regr_tdb116_remove_region_write 已移交 iotdb-remove-cn-dn skill

该 PLM 条目要"并发 REMOVE REGION/节点移除 × 跨时间分区写入"，属**破坏性集群操作**（会改动集群拓扑），
不适合放在以增删改查语义为定位的 CRUD skill 里。已按用户指示移交 `iotdb-remove-cn-dn` skill
（工作区内 `.dsh/skills/iotdb-remove-cn-dn`，数据驱动：`cases/remove_cases.tsv` 的 target/selector/abnormal 列）。
CRUD 侧不再保留该用例，也不再用弱化断言凑 PASS。


## 2026-10-07 收尾：新增 3 条新维度用例 + TDB-116 移交 + 集群停止

**(3) 新增 3 条新维度用例，均已单跑真实 PASS（逐条 `run --case`，证据在各 run 的 actions.log）**
- `crud_ttl_x_crud_delete`（TTL × CRUD 交叉）：SET TTL 3600000 后全量删除，断言数据清空、
  `SHOW TTL ON <db>.**` 仍返回 3600000（删除不破坏 TTL 元数据）、TTL 生效期间重新写入仍可读。
- `crud_table_delete_granularity`（表模型删除粒度）：4 行中 `time <= 101000` 删除后剩 2 行（首版我把
  期望写成 3 行，属**用例自身算错**，已按实测更正）；`drop table` 后重建为空表、可再次写入并回读。
- `crud_schema_change_write`（Schema 变更后写入）：INT32 时序写 INT32 成功；写 DOUBLE 被拒且不落库
  （写入失败不产生行）；新测量点 `s2` 自动建并可写入。

**注册坑（经验）**：新用例行写进 `cases/crud_cases.tsv` 时，标题含全角标点/多字段会被解析器丢行
（表现为 `unknown case id`），改成与既有行一致的 ASCII 标题后正常注册。改完务必用 `list-cases` 复核条数。

**(1) `crud_regr_tdb116_remove_region_write` 已移交 `iotdb-remove-cn-dn`**
- CRUD 侧：TSV 行已删除（`list-cases` 无残留、`grep` 计数 0），run-log 说明改为指向新位置；
- remove-cn-dn 侧：在 `cases/remove_cases.tsv` 增加 `dn_concurrent_remove_writes_tdb116`
  （列取自同类 `dn_multi_remove` 行：`dn | multi | none | 3 | default | default`），
  即"多 DataNode 顺序移除 + 读写下"的跨分区写入回归；
  **如实说明**：该 skill 的框架以 CN/DN 移除为操作对象，并不逐字执行 `REMOVE REGION`，
  因此该行覆盖的是"移除过程中的跨分区写入"这一等价场景；**其执行尚未运行**（需要另起
  remove-cn-dn 集群，与"释放机器"冲突），执行前不得视为已通过。

**(2) RC5 集群已停止，机器已释放**
用 kit API `Cluster(cfg, ssh, sql, log).stop_all()` 优雅停止（CLI 无 `stop` 子命令），
停后 5 台主机 `pgrep -c java` 全部为 0；停止动作的 run 目录：`results/20261007_171840_stop`。
停集群前的最后一次全矩阵认证仍是 `results/20261007_160634_matrix`（71 PASS / 0 FAIL / 1 SKIP），
其中那条 SKIP 就是这个已移交的 TDB-116；**新增 3 条与摘除 TDB-116 之后未再跑全矩阵**
（需要重启集群），如需最终全量认证，重启后跑一次即可。


## 2026-10-07 最终全量认证（并入 3 条新用例、摘除 TDB-116 后）

- run 目录：`results/20261007_192320_matrix/`（REPORT.md 为总报告）
- 真实结果：**72 PASS / 2 FAIL / 0 SKIP**，共 74 条
- 与上一次认证（`results/20261007_160634_matrix`，71 PASS / 0 FAIL / 1 SKIP）的差异：
  新增 `crud_ttl_x_crud_delete`、`crud_table_delete_granularity`、`crud_schema_change_write` 三条并全部 PASS；
  摘除已移交 iotdb-remove-cn-dn 的 `crud_regr_tdb116_remove_region_write`（该 skill 侧用例行尚未执行）。
- 集群在认证后再次停止释放机器（见本轮 stop 记录与 5 台主机 java 进程检查）。


## 2026-10-07 最终认证（修正两处用例缺陷后）

矩阵内两条新用例曾 FAIL，根因都是**用例自身缺陷**，已修：
1. `crud_ttl_x_crud_delete` 与 `crud_schema_change_write` 共用 `root.crud_x` 库，矩阵内互相干扰 ⇒ 拆成
   `root.crud_ttlx` / `root.crud_schg`；
2. `crud_ttl_x_crud_delete` 用 2023 年固定时间戳，设了 TTL=1h 后被**过期检查**清掉（单跑时检查尚未触发，
   属侥幸 PASS）⇒ 改用当前时间戳。
修后结果：`results/20261007_200207_matrix/` = **74 PASS / 0 FAIL / 0 SKIP**（共 74 条）。
教训：**带 TTL 的用例不能用远过去的固定时间戳**；**每个用例必须独占数据库名**，否则单跑 PASS、矩阵 FAIL。


## 2026-10-08 完整一轮耗时实测（从部署开始）

在 RC5 上按 deploy → prepare → doctor → matrix 全流程跑一遍，分阶段**实测**耗时（`date +%s` 差值，非估算）：

| 阶段 | 耗时 |
| --- | --- |
| deploy（安装/启动 3CN+5DN） | 29 s |
| prepare（清理与预处理） | 128 s |
| doctor（前置检查） | 6 s |
| matrix（74 条用例） | 1979 s（32 分 59 秒） |
| **合计** | **2142 s（35 分 42 秒）** |

- 结果：**74 PASS / 0 FAIL / 0 SKIP**，run 目录 `results/20261007_212130_matrix/`。
- 用例耗时合计 1980s（矩阵墙钟 1979s 含用例间开销）。
- 最慢 10 条：
  1. `crud_regr_tdb442_combo` 376.0s（回归）
  1. `crud_schema_auto_create_off` 309.8s（元数据）
  1. `crud_consistency_after_restart` 199.1s（一致性）
  1. `crud_huge_batch` 188.4s（边界）
  1. `crud_consistency_wal_replay` 177.1s（一致性）
  1. `crud_regr_tdb184_query_reserved_size` 57.9s（回归）
  1. `crud_concurrent_delete_query` 29.3s（并发）
  1. `crud_regr_tdb442_delete_compaction` 21.2s（回归）
  1. `crud_concurrent_delete_insert` 16.8s（并发）
  1. `crud_ttl_x_crud_delete` 16.2s（TTL）

- 结论：CRUD 全量一轮 ≈ **36 分钟**，其中带重启的 props 覆盖类用例与 iot-benchmark 负载类用例是主要耗时来源；
  部署与准备合计不到 3 分钟（tarball 已在本机缓存）。
