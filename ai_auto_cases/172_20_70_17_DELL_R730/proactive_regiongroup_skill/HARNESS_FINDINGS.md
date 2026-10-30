# harness 发现（构建期踩坑与修正）

> 这些不是产品缺陷，而是"测试脚本本身会制造假 PASS / 假 FAIL"的地方，已修正并固化到代码。

## H-01 `time_partition_interval` 单位是毫秒，曾写错 1000 倍

* 症状：跨时间分区类用例的窗口与设计意图不符（7 天 → 10 分钟）。
* 修正：所有档位改为 `604800000`；用例一律用 `SHOW DATABASES DETAILS.TimePartitionInterval`
  实测值算边界，**禁止硬编码**（`cases.py`/`cases_msr.py` 已如此）。
* 关联：`references/doc-gaps.md` G-09。

## H-02 上限断言曾按"单一方言的分摊库数"算，会假 FAIL

* 症状：树库 `root.pg` 与表库 `pg` 并存时，`SHOW DATABASES DETAILS`（按方言过滤）只看到 1 个库，
  算出上限 5；产品实际按 2 库分摊 ⇒ 上限 3 ⇒ 用例假 FAIL。
* 修正：`cases.expected_cap()` 取树+表两方言的**并集**；族模块另用 `_solo_*` 归一化把库数压到 1。
* 关联：G-08。

## H-03 表方言不支持 `… REGIONID` / `SHOW TIMESLOTID`

* 症状：表模型用例发 `SHOW DATA REGIONID` 抛 `SemanticException`，被当成产品错误。
* 修正：三大观测面交叉验证只在树模型做；表模型只用 `SHOW DATABASES DETAILS` + `SHOW … REGIONS`。
* 关联：G-07（`AstBuilder.java:1781/1785`）。

## H-04 收尾②"停全部 DN"是 5 倍成本且非用户口径

* 症状：逐台停 5 个 DN，每台停/起后还要各等一次 sync lag 归零（60s 稳定窗口）⇒ 每例 4~5 分钟。
* 修正：`REPLICA_MODE=both` + `CONSISTENCY_STOP_NODES=1` = 全在线基线（5 台各查一遍）+ 停 1 台复核，
  与用户要求一致，成本降到 ~1/5。

## H-05 并发触达集群会污染日志窗口（最严重的一次假 FAIL）

* 事件：一个子代理在活集群上跑负向用例（`set configuration` 非法值），DN 记录
  `ConfigExecution WARN + 栈`；同时主 agent 的用例窗口扫到这些行 ⇒ 被判"非预期异常"FAIL。
* 教训：**一个集群同时只能有一个 runner**；负向用例必须在语句前开归因窗口
  （`ctx.mark_harness_action`），但**跨进程/跨 runner 的并发无法归因**，只能靠执行纪律隔离。
* 处置：本项目把"禁止触达集群"作为子代理的硬约束；主 agent 串行驱动所有轮次（`drive_runs.sh`）。

## H-06 fixture 的 drop 会产生固有 WARN

* 症状：`reset_db` 无条件 drop（树方言无 `if exists`），首次运行时服务端记录删除不存在的库的 WARN；
  收尾③会把它算成非预期。
* 修正：`reset_db` 自动 `mark_harness_action`（pad=30s），日志扫描把窗口内命中归入 `log_attributed.txt`。

## H-07 写入夹具必须自动登记收尾②对拍查询

* 症状：用例写了数据但没登记查询 ⇒ 收尾②报"no consistency query was registered"（假 FAIL）。
* 修正：`ensure_write_tree/ensure_write_table` 内部调用 `ctx.note_data_written()` 自动登记
  `select count(*)`（按对象去重）；确实没写数据的用例（空库/纯观测）走"无需对拍"分支。

## H-09（修正版）`GrpcLogAppender … is interrupted` 未被归因：**模式已有，缺的是"停机动作"窗口**

* 关键事实（本轮核对源码）：`scripts/pgkit/verify.py:44` **早已存在**
  `(r"GrpcLogAppender:\d+", "IoTConsensus/Ratis 启动收敛期的 appender 提示")`，
  所以**不是"缺模式"**——我上一版把它写成"要新增模式"是错的，此处更正。
* 真实原因：该模式的生效范围被限制在**节点启动收敛期窗口**内，而本次命中发生在
  2026-10-14 21:09:20~21:09:29（收尾②停/起 DataNode `11.101.10.8` 之后约 2 分钟），
  已落在启动窗口之外 ⇒ 未被归因。
* 证据（`PG-SMK-04` 收尾③，三台节点首个命中项一致）：
  `dn@11.101.10.7: … [3@group-000200000008->2-GrpcLogAppender-LogAppenderDaemon] WARN
  o.a.r.g.s.GrpcLogAppender:299 - 3@group-000200000008->2-GrpcLogAppender is interrupted`；
  `dn@11.101.10.6: … [4@group-00020000000A->5-GrpcLogAppender…]`；
  `dn@11.101.10.10: … [5@group-000200000008->3-GrpcLogAppender…]`（均为 `at least 2 hit(s)`）。
* 归因结论：`X@group-…->Y-GrpcLogAppender is interrupted` 表示"本节点到节点 Y 的日志追加器被打断"，
  而 Y 正是本用例收尾②主动停掉/重启的那台 ⇒ **属本项目自身动作噪声**。
* 修法（不要新增重复模式，也不要放宽成无条件白名单）：
  1. 复用既有的"模式 + 窗口"机制：在**收尾②每次停/起 DN** 时注册一个归因窗口
     （覆盖该动作时刻 **+ 其后约 180s** 的尾巴，与已有的 `CONSENSUS_CONVERGENCE` 尾窗做法一致），
     使 `GrpcLogAppender.*is interrupted` 落在该窗口内才被排除；
  2. 该窗口只在本用例确实对**该节点**做过停/起时生效（按 host 匹配，不要全局放宽）；
  3. 窗口之外出现的同类 WARN 仍必须照常 FAIL。
* 影响：`PG-SMK-04` 的 2 个 FAIL 至此**全部归为 harness 类**（H-10 期望口径 + H-09 日志窗口），
  产品侧在该例没有可判缺陷；但这不等于"产品无问题"——D-05 等真实 FAIL 仍须保留。
## H-10（重要）用"现场重算的上限"当期望值 = 系统性假 FAIL：上限是每库单调存量，不是实时公式量

* 现象（run `pg_core_iot2` / `PG-SMK-04`）：`写入第 4 个 slot 后：SchemaRegionGroup 数应为 3`，
  实测 `库详情=4、区域去重=4`（两口径一致，产品行为自洽）。
* 根因（已定位到代码，`scripts/pgkit/cases.py:438-440`）：
  ```python
  cap_s, cap_d = expected_cap(ctx, "SCHEMA", "tree", db), expected_cap(ctx, "DATA", "tree", db)
  ...
  expect_groups(..., schema=min(index, cap_s), data=min(index, cap_d))
  ```
  `cap_s` 是**现场**按公式 `ceil(weight×resource/(库数×副本数))` 重算的：该例跑到第 4 个 slot 时，
  测试库集合是 {树库 root.pg, 表库 pg}（SMK-02 建过表库且未被清掉）⇒ `ceil(3×5/(2×3))=3`。
  但**产品侧的上限是每个库各自保存的存量值**：`adjustMaxRegionGroupNum()` 只会
  `max(min, …, allocated)` 地**单调抬高**、从不因别的库加入而回落（入库数变化只影响"下一次调整"）。
  该树库在建库/首次调整时库数为 1 ⇒ 上限算得 5，于是组数按 `min(K=4, 5)=4` 增长 —— **产品是对的**。
* 定性：**harness 期望值缺陷（H-10）**，不是产品缺陷（此前记录为"D-07 候选"的条目据此关闭，
  原始证据保留在 `DEFECT_CANDIDATES.md` 备查）。
* 修法（不能靠白名单，必须改判定口径）：
  1. 组数类断言一律以**产品自报的上限**当 oracle：
     `expected = min(K, ctx.api.db_max_group_num(db, kind, dialect=...))`，
     因为 `SHOW DATABASES DETAILS` 的 `Max*RegionGroupNum` 就是该库当前生效上限；
  2. "上限值本身是否等于公式"单独在**库集合受控**的用例里验（`PG-LIM-*`、`PG-EMPTY-09`、
     `PG-SYS-*` 已按此设计：这些用例先固定库集合再读上限，且断言的正是产品自报值 vs 公式）；
  3. 涉及多库并存的用例（SMK-04/05、DEV/MSR/TIME 等）不得再用"现场公式"作期望。
* 影响面：同一模式可能波及所有"先建多种库、再断言组数"的用例 ⇒ 需要一次口径普查
  （把 `min(index, cap_*)` 形态全部改为产品自报上限）；本条与 H-08（分摊库数口径）是同一根因的两面。

### H-10 附：受影响断言普查（113 处 / 8 模块 / 66 用例）

普查口径：正则 `min(...cap_s|cap_d)` 或 `min(...expected_cap(...)` —— 即"用现场重算的上限当期望"。
逐条位置见 `references/h10-census.txt`。分布：

| 模块 | 处数 | 用例数 |
|---|---|---|
| cases.py | 15 | 9 |
| cases_cfg.py | 3 | 2 |
| cases_dev.py | 20 | 7 |
| cases_lim.py | 18 | 9 |
| cases_msr.py | 26 | 19 |
| cases_ops.py | 7 | 6 |
| cases_ops2.py | 23 | 13 |
| cases_swch.py | 1 | 1 |

**机械修法（不要逐例手改判定语义）**

1. 在 `cases.py` 新增一个纯函数，与 `expected_cap` 并存、语义不同：

   ```python
   def group_ceiling(ctx: Ctx, kind: str, dialect: str, db: str) -> int:
       """组数类期望的上限口径：产品自报上限优先（上限每库单调不减），
       库尚不存在时退回公式值。"""
       formula = expected_cap(ctx, kind, dialect, db)
       try:
           reported = ctx.api.db_max_group_num(db, kind, dialect=dialect)
       except Exception:
           reported = 0
       return max(formula, reported) if reported else formula
   ```

2. 把 `references/h10-census.txt` 列出的 113 处里的 `expected_cap(` 改为 `group_ceiling(`；
   涉及 `cap_s`/`cap_d` 的用例，把取值处改为
   `cap_s = group_ceiling(ctx, "SCHEMA", dialect, db)`（同理 `cap_d`）。
3. **不要动** `PG-LIM-*`/`PG-EMPTY-09`/`PG-SYS-*` 中"断言上限值本身 == 公式"的那几处断言：
   它们验证的正是产品自报上限与公式的一致性，属于受控库集合下的独立判定
   （这些断言的 oracle 是 `db_max_group_num` vs `expected_cap` 的**直接比较**，不是 `min(K, cap)` 形态）。
4. 改完必须跑：`selftest`（687+ 检查）与一次 `--tier smoke` 复跑，确认 SMK-04/05 由 FAIL 转 PASS
   且**没有**把真缺陷一起改没（对照 D-05 等仍在的 FAIL）。

### H-10 附二：普查口径更正 + 落地结果（重要，避免把"高估"当成 72 处未修缺陷）

**已落地（本轮，`selftest` 全绿、注册表仍 217 条）**：新增 `cases.group_ceiling()`，
并按"取值处"语义机械替换 **41 处**：

| 形态 | 处数 | 覆盖模块 |
|---|---|---|
| `cap_s/cap_d = expected_cap(...)` → `= group_ceiling(...)` | 24 | cases.py、cases_cfg.py、cases_ops.py、cases_ops2.py、cases_swch.py |
| 行内 `min(..., expected_cap(...))` → `min(..., group_ceiling(...))` | 17 | 同上 |

**普查口径更正**：`references/h10-census.txt` 的 113 处是**按语法形态匹配**（`min(...cap_s)`），
并未判断 `cap_s` 从哪来 ⇒ 属**高估**。逐族核实后：

* `cases_msr._caps` / `cases_dev._caps` —— **本来就正确，且更严格**：它们把"公式值"与
  "产品自报 `Max*RegionGroupNum`"**对拍**，不一致就 SKIP / 提前返回（dev 的注释明确写了
  "本族的职责是验证扩展行为，不是校准上限公式"；dev 还额外用**双模型库数**修正了分母，
  即 G-08/H-08 那条口径）。因此这两族**不存在**用公式当期望的假 FAIL 风险。
* `cases_lim._cap` —— **故意**用公式：LIM 族验的就是"上限值本身 == 公式"，且库集合受控。
* 真正的暴露只有"直接拿裸公式当组数期望"的那 41 处，已全部改为 `group_ceiling`。

**结论**：H-10 的产品影响面 = 0（是 harness 期望口径问题）；修正后 113 处里剩余的 72 处
**无需改动**，不是遗留缺陷。后续若再跑普查脚本，必须同时打印"该 cap 的赋值来源"，
否则会重复这次的高估。

#### H-09 机制确认（已读源码，修法就此锁定）

`scripts/pgkit/verify.py:771-785` 的归因逻辑是：

```python
def _attribute(line, windows):
    if not windows: return None
    epoch = _line_epoch(line)
    if epoch is None: return None
    for pattern, reason in HARNESS_INDUCED_PATTERNS:
        if not re.search(pattern, line): continue
        for start, end, why in windows:
            if start <= epoch <= end:
                return f"{reason}（harness 动作: {why}）"
    return None
```

要点：
1. 判定 = **模式命中 AND 行时间戳 ∈ 任一窗口**；`HARNESS_INDUCED_PATTERNS` 里的
   `GrpcLogAppender:\d+`（第 44 行）**本身没有**"仅启动收敛期"的硬条件，
   "启动收敛期"只是它被放进的那批窗口的**语义注记**。
2. 窗口来源：`check_logs(since_epoch=..., expected_windows=...)` 内部合并
   `expected_windows + self.extra_windows`（`verify.py:694-698`，`extra_windows` 见 `:411`）。
3. 因此本次 FAIL 的唯一原因是：21:09:20~29 那批 `is interrupted` **不在任何已注册窗口内**
   ——收尾②停/起 DN 的动作时刻没有被登记成窗口（只在"集群启动收敛期"登记过）。

**精确改点（下一轮照此实现，风险很低）**：在 `closing_triad` 的收尾②里，每当它停/起一台
DataNode，就向 `verify.extra_windows` 追加 `(动作时刻, 动作时刻 + 180, f"停/起 DN {host}")`；
该窗口按 host 归属（只影响该节点日志的归因判断，因为窗口只是时间区间，配合模式使用）。
窗口之外出现的同类 WARN 仍照常 FAIL ⇒ 判定口径不被削弱。

#### H-10 安全性论证（用真实运行反证：修正不会掩盖 D-04）

`group_ceiling = max(公式, 产品自报上限)` ⇒ **只能抬高期望**，不会降低。而 D-04 的形态是
"产品自报上限被钉在最小值、组数完全不涨"，此时 `自报值 < 公式值` ⇒ `group_ceiling` 返回的仍是
公式值，**期望与修正前完全一致**。

运行反证（`pg_core_iot2`，加载的是修正前代码，但形态等价）：`PG-SMK-05`（表模型）报
`表模型写入第 2/3/4 个设备后：SchemaRegionGroup 数应为 2/3/3`，实测 `库详情=1、区域去重=1`；
`DataRegionGroup 数应为 3/4`，实测均为 `2` —— 即表库的 Schema/Data 组数**停在最小值不动**
（= **D-04 复现**，产品缺陷）。这类"产品给得比公式少"的场景，H-10 修正后仍会如实 FAIL。

结论：H-10 只消除"现场公式 < 产品存量上限"造成的假 FAIL（SMK-04 型），
**不可能**把 D-04/D-05 这类真缺陷改没 —— 这正是验收标准所要求的性质。

#### H-09 已落地（`verify.py` 收尾②登记停机动作窗口）

在 `scripts/pgkit/verify.py` 收尾②停 DataNode 成功之后（`:546` 一带）插入：

```python
_stop_epoch = time.time()
self.extra_windows.append(
    (_stop_epoch - 5, _stop_epoch + 300,
     f"收尾②停 DataNode {host}（对端 appender 中断等自身动作噪声）"))
```

* 为什么是窗口而不是新模式：`HARNESS_INDUCED_PATTERNS` 第 44 行的 `(r"GrpcLogAppender:\d+", …)`
  本就存在，`_attribute()` 的判定是"模式命中 **AND** 行时间戳 ∈ 某窗口"；缺的只是覆盖停机后的窗口
  （默认 `mark_harness_action` 只有 ±15s，盖不住约 2 分钟后才出现的对端追加器中断）。
* 为什么尾巴取 300s：收尾②"停机 → 等待 settle → 切查询主机复测 → 重启该节点"整段都在这段时间内。
* 判定强度未被削弱：窗口是**时间区间**，窗口之外出现的同类 WARN 仍照常 FAIL；
  产品自身的中断类异常（与本次停机无关的时刻）也不会被吞掉。
* 验证：`selftest` 全绿、注册表仍 217 条（改前备份 `scripts/pgkit`，失败即回滚）。

## H-11（**已定性为 harness，已修**）切换回 PROACTIVE 后组数按 K 全额增长，用例却期望"+1"

* 证据（`pg_core_iot2` / `PG-SMK-06`）：检查 `切回 PROACTIVE 后新 slot 继续扩容（组数 +1）`
  实测 **`切回后=5（期望 4）`**。
* 两种可能（**必须先读用例代码再定性，不得凭猜**）：
  1. **harness**：切回 PROACTIVE 时产品按公式 `T = min(R, max(min(minNum, G+|P|), K))` 以
     **当前全部 K 个 slot** 重新评估（K=5）⇒ 给 5 正确；而用例把它当成"在旧组数上 +1"（3+1=4）。
     若如此，属与 H-10 同族的期望口径问题（把"增量"当成了"全量公式"）。
  2. **产品**：若产品在"切回"时**超额/重复**建组（超出 `min(K, R)`），则是真实缺陷。
* 判定方法：读 `cases.py` 的 `case_smk06*`（或 `cases_swch` 的 SWCH-01），确认该步期望是
  `prev + 1` 还是 `min(K_total, ceiling)`；前者按公式改正（H 类），后者升级为 D-08（产品）。
* 影响：该例其余检查（切换不建组、AUTO 期间保留已有组）不受影响；
  **在定性前不得写成产品缺陷**。已一并确认"`classify_fails.sh` 分类器"能在一条命令里
  列出所有 FAIL 的检查名/实测值/日志首命中，后续新 FAIL 一律先过它再定性。

### H-11 结论与修法

读源码确认（`cases.py` `case_smk06*`）：该步原为 `after_pro == before + 1`（3+1=4），
忽略了**公式用的是全量 K**：`K = 已分配 ∪ 待分配 的 series slot`，AUTO 期间写入的 slot 仍缺组
⇒ `T = min(R, max(min(minNum, G+|P|), K)) = min(R, 5) = 5`，**产品给 5 正确**。

已改为：`want = min(5, group_ceiling(ctx,"DATA","tree",db))`，检查名改为
"切回 PROACTIVE 后补齐 AUTO 期间的新 slot（组数按全量 K 增长）"——把这条**积极扩容的核心语义**
从"顺带断言"提升为显式断言（策略切换期间写入的 slot 会在切回后被补齐）。
`selftest` 全绿、注册表 217 条（改前备份，失败即回滚）。

#### H-10 附三：替换后的一处不对称（已实测，无影响）

`cases.py:447/462` 是**同一行两处赋值**：
`cap_s, cap_d = group_ceiling(..., "SCHEMA", ...), expected_cap(..., "DATA", ...)`
——机械替换只命中了 `cap_s`，`cap_d` 仍走公式。**当前无影响**（已实测）：

* `SMK-05`（D-04 用例）：`cap_s = max(公式 3, 自报 1) = 3`、`cap_d = 公式 30`
  ⇒ 期望 `min(index, 3/30)` 与修正前**完全一致** ⇒ D-04 的 4 条组数断言照旧 FAIL（不被掩盖）。
* `SMK-04`：数据侧 `min(K=4, 30) = 4`，实测本就是 4，两种口径同值。

后续若要统一为 `group_ceiling`，**必须先跑一轮验证**再改：因为 `group_ceiling` 可能把期望从
公式值抬到更大的自报值，在"产品确实滞后"的场景下会新增 FAIL（属**真实** FAIL，但需逐条复核
是产品问题还是库集合变化所致），不可无验证地批量替换。

## H-12 用例把 `snapshot()` 的 dict 当"行列表"迭代（已修，`ErrorCase` 类）

* **现象**：`pg_core_iot2` / `PG-EMPTY-03` FAIL —— 检查 `用例执行未抛异常`：
  `TypeError: string indices must be integers`。
* **真因**：`ctx.api.snapshot()` 返回的是 **dict（RegionId → 信息）**，而用例写成
  `{g["region_id"] for g in before}` —— 迭代 dict 得到的是**字符串键**，再按键索引即抛该错。
  （注意：这条用例**不是**产品失败，而是用例自身代码错误，属"不得把 harness 错误记成产品缺陷"的典型。）
* **修法**：新增辅助 `region_ids(snap)`（兼容 dict 与 list-of-dict 两种形态），并把
  `{g["region_id"] for g in X}` / `sorted(g["region_id"] for g in X)` / 行内迭代表达式
  共 **7 处**统一替换（`cases.py` 6 处 + 行内 `ctx.api.snapshot(...)` 1 处）。
* **验证**：`ast` 通过、`selftest OK`、残留同类模式扫描为 0（改前备份 `scripts/pgkit`，可回滚）。
* **教训（已并入交接说明）**：凡是 API 返回 dict 的读取，统一走辅助函数；新用例必须先过
  `selftest` + 一轮 `PG_TIER=smoke` 才能进 core 轮，避免"异常即 FAIL"污染统计。

### H-12 附：全量静态预检（结论：无残留同类缺陷）

修完 H-12 后对**全部用例族**做了两类扫描，结果如下，今后无需重复怀疑同一形态：

1. **历史轮次崩溃扫描**（扫 `results/*/cases/*/result.json` 中"用例执行未抛异常"失败的用例）：
   全部轮次仅 **2 例**——`PG-EMPTY-03`（H-12，已修）与 `PG-SMK-03`
   （早期 `closing_triad` 里 `Config.get_int(key, default)` 的参数个数错误，已在启动 `pg_core_iot2` 前修复）。
   即**已执行部分没有第三个用例级崩溃**。
2. **dict 迭代形态扫描**（`for x in ctx.api.*` 全部 5 处）：
   * `cases_ops.py:772` 用 `.values()` ✓；
   * `cases_ops2.py:139` / `cases_lim.py:82` / `cases.py:342` / `cases_ops2.py:130` 迭代
     `database_details()` 得到的**库名字符串键**，循环体分别用作 `name in n`、`name in ...`、
     `user_dbs.add(name)`、`names.add(name)` —— **均为正确用法**。
   * `snapshot()` / `snapshot_all()` 的"值即信息 dict"用法已由 H-12 的 `region_ids()` 统一收口，
     残留 `{g["region_id"] for g in ...}` 模式为 **0**。

**注意范围**：以上只能证明"已执行 + 已写代码"的部分无残留；剩余约 185 条未执行用例若仍有
未知形态的 API 误用，只会在执行时暴露——这也是"每轮 FAIL 一律先过 `classify_fails.sh`
区分产品/ harness"这一纪律必须坚持的原因。

### H-12 附二：全量 AST 签名预检（结论：0 处真实不匹配）

对**全部 217 条用例的代码**做了两类不依赖集群的静态预检：

| 预检 | 规模 | 结果 |
|---|---|---|
| `ctx.api.<方法>()` 名称/位置参数个数/关键字名 与 `pgapi.py` 真实签名比对 | 49 个 API 方法 | **0 处可疑** |
| 模块级辅助函数（`ensure_write_tree`/`device_set`/`expect_groups`/`expected_cap`/`group_ceiling`/`region_ids` 等）调用签名比对 | 全部辅助函数 | 报告的 7 处经逐条核实**均为误报** |

7 处误报的原因：`log` 与 `ctx_factory` 在 `cases.py` 中既是模块级函数名，也是某些函数的**形参名**
（`run_cases(specs, ctx_factory, run_dir, log)` 等注入的回调）；调用点 `log(msg)`、`ctx_factory(spec, case_dir)`
用的正是**传入的回调**，属正确写法。审计脚本未做形参遮蔽分析，故把它们记为可疑。

**意义**：把"API/辅助函数签名误用"这一类**只会在执行时暴露的用例缺陷**（如早前的
`insert_tree(device_path, stamp, measurements, values)` 与 `db_max_group_num(db, kind, dialect=...)`
关键字-only 参数）提前清扫干净，避免它们以 FAIL 形式混进结果、被误当产品问题。
仍需执行时才能暴露的是"语义误用"（例如 H-12 那种把 dict 当列表迭代），因此
"每个 FAIL 先过 `classify_fails.sh`" 的纪律不变。

## H-13 TTL 规则跨用例污染（已修，影响 IoTConsensus 轮 25 例）

* **现象**：`pg_core_iot2` 中 25 例以 `AssertionError: insert … failed: 607: Insertion time [1970-01-01T08:16:40]
  is less than ttl time bound [2026-10-15T07:16:50.302]` 崩溃，涉及 `PG-SWCH-01..12`、`PG-RST-01/02/03/06`、
  `PG-PRV-05/07/08`、`PG-SYS-04/06`、`PG-TTL-02/03/08`、`PG-HA-12`。
* **真因**：**TTL 规则按路径持久化在配置中，`drop database` 不会连带清除**。`PG-TTL-*` 用
  `set ttl to <db>.** <ms>` 设了规则后未清理，其后所有用例的 fixture 写入（`stamp=1` ⇒ 1970）都被 TTL 拒绝。
  这不是产品缺陷，也不是用例逻辑错，而是**前置状态被污染** ⇒ 该批判为 **INVALID，需修后复跑**。
* **修法（两层）**：① `cases_ops2._set_ttl` 成功即把 `unset ttl from <path>` 追加到 `ctx.cleanup`
  （由 `run_cases` 的 finally 逆序执行）；② `cases.reset_db` 增加防御性 `clear_ttl(ctx, db)`，
  在每次 drop/create 前兜底清理。
* **教训**：凡是**跨用例持久化**的服务端状态（TTL 规则、配置项、用户/权限、只读状态、策略档位），
  用例必须自查自清；fixture 应在建库前先把已知持久态复位。

## H-14 语法探测动作缺模式/窗口（已修）

* `set ttl to <path> to <ms>`（需求文档给的写法）在 2.0.11 被 CN 解析成路径 `root.pg.**to`，
  返回 `303 Illegal pattern path` 并在 DN 侧打 WARN `ClusterConfigTaskExecutor:1297 Failed to execute set ttl …`。
  我的 `_set_ttl` 会**先后探测**两种写法 ⇒ 这条 WARN 是"自己探测"的产物。
  处置：`_set_ttl` 登记 `mark_harness_action`（窗口）+ `verify.HARNESS_INDUCED_PATTERNS` 补
  `Failed to execute set ttl`（仍需窗口同时命中才归因）。
* `alter database … max_*_region_group_num` 在非 CUSTOM 策略下被按设计拒绝
  （`525 … can only be set when *_extension_policy is CUSTOM`）。`cases_lim` 的 LIM-14/15、DIS-02
  **早已登记** harness 动作窗口（pad=20），缺的只是模式 ⇒ 已补
  `Failed to execute alter database.*max_(schema|data)_region_group_num`。
* **不削弱判定**：两条模式都必须**同时**命中 harness 动作窗口，窗口外的同类 WARN 照常 FAIL。
* **副产物（文档口径，记入 `references/doc-gaps.md`）**：需求/设计文档给出的 TTL 写法
  `set ttl to <db>.** to <ms>` 在当前版本不可用（303），实际可用的是 `set ttl to <db>.** <ms>`；
  另外 PROACTIVE/AUTO 策略下**不能**用 `ALTER DATABASE` 改 `max_*_region_group_num`（须 CUSTOM），
  这一点直接影响"如何把表模型上限从最小值调大"的操作路径。

## H-17 日志扫描缺"本轮 run 起点"硬下界（已修）

* **现象**：`pg_smoke_fix3` 的 `PG-SMK-02/03/04` 收尾③ 仍报日志命中，且**模式已修好**（H-16）——
  命中的是 `GrpcLogAppender$AppendLogResponseHandler:531 received INCONSISTENCY reply` 等**启动收敛期** WARN，
  时间戳（如 13:54:19）**早于本轮用例起点**（13:56:5x）。
* **真因**：`since` 只取"用例开始 / fixture 完成 / 集群就绪"三者最晚，**没有本轮 run 的硬下界**；
  上一轮 run 起的集群进程在本轮用例开始前仍在写日志，其引导期 WARN 会被本轮扫描误纳。
  另：收敛期窗口按 `DN uptime < 300s` 判定，而"集群是上一轮起的"时 uptime 已经 757s ⇒ 窗口不开。
* **修法**：`cases.py` 增模块级 `_RUN_STARTED = time.time()`（≈ 本轮 runner 启动），
  收尾③ 的 `since` 取 `max(since, _RUN_STARTED)`。**只排除本轮之前的行**，本轮任何产品异常仍会 FAIL。
* **连带更正（H-16 之后仍在的窗口判定）**：集群是**上一轮**拉起时，`_mark_convergence` 不会开窗
  （uptime 已超阈值）——这本身合理；配合 H-17 后，这些陈旧行不会再进入扫描窗口。

## H-18 我的 H-10 修复漏了导入（已修，回归自伤）

* **现象**：`PG-TTL-01` 收尾报 `NameError: name 'group_ceiling' is not defined @ cases_ops2.py:243`。
* **真因**：H-10 把上限期望改为 `group_ceiling(...)`（定义在 `cases.py`），但只改了调用点，
  `cases_cfg.py` / `cases_ops.py` / `cases_ops2.py` / `cases_swch.py` 四个模块**没有导入该符号**。
  冒烟档只跑到 `TTL-01` 才暴露；core 档里同类崩溃会被记成"用例执行未抛异常"，属**harness 自伤**。
* **修法**：四个模块的 `from .cases import (...)` 块补 `group_ceiling`；`ast` + `selftest` 通过。
* **教训**：跨模块改动符号后，必须用"全模块 ast/导入检查"（`selftest` 已覆盖）而不是只跑单个用例。

## H-19 上限对拍口径错：应容忍"自报 > 公式"（上限是每库单调不减的存量）

* **规则（本轮固化为判定口径）**：产品为**每个库**保留**单调不减的历史上限**（多库分摊时也不即时收缩），
  因此 `db_max_group_num` **可以大于**源码公式（如自报 20、公式 15）= **预期行为**；
  **只有 `实测 < 公式` 才算失败**。凡"仅因 实测 > 公式 / 实测 == 自报 ≠ 公式"而 FAIL 的，
  一律判 harness 判定口径问题，**不得记产品缺陷**。
* **源码依据**：`iotdb-core/confignode/.../PartitionManager.java:654-699` 的
  `customExtendRegionGroupIfNecessary`/上限维护只做"单调抬高"，库集合变化只影响"下一次调整"；
  另见 `:701-722`（CUSTOM 一次补满）与 `ClusterSchemaInfo.getMinRegionGroupNum:748-771`（读库内存量 min）。
* **首轮观测（保留）**：`pg_smoke_fix3` 的 `LIM-01/LIM-03/SYS-01/TIME-01/MSR-01` 全部是
  `公式={'SCHEMA': 2, 'DATA': 15}`、实测 `{'DATA': 20}`，即 **自报 20 > 公式 15**；
  属 **H-10 家族**，不是 D-04（D-04 的形态是"自报 < 公式/最小值"，如 `SMK-05` 表模型 Schema=1/Data=2 钉在最小值）。
* **本轮规模（217 例全量）**：**17 例 / 69 个 check** —— `LIM-21`、`LIM-01/03/05/06/07/08/11/12/13/16/18/20`、
  `MSR-13`、`SYS-01/02`、`TIME-10`。其中 **68 条为 `实测 > 公式`**，
  仅 `PG-LIM-07[8]` 一条为 `实测 < 公式`（该步读到 5，紧接的"恢复 data=0 后"立刻读到 60 ⇒ 产品异步调整、
  用例缺等待，也不是缺陷）。逐 check 的"实测 vs 公式"见 `../TRIAGE_full_round.md` §4.3（293–317 行）。
* **标签差异（据实登记）**：`PG-HA-05` 在 TRIAGE §4.0 / 附录 A 写作 `H-19+LOG(harness)`，
  但它的 2 个失败 check 在 §4.5 被归入"期望公式漏 `minNum` 项"，并计在 H-26/27/28 的 37 check 里
  ⇒ 本条按 §4.3 表统计为 **17 例 / 69 check**（不含 HA-05）。按 §4.0 标签计则为 18 例；
  两种标签不影响"该例失败原因是期望值建模错、应修正后 PASS"的结论。
* **改法（下一步，尚未落地）**：
  1. 对拍检查在 `自报 < 公式` **或** `自报 < 最小组数` 时才 FAIL；`自报 > 公式` 记为 note；
  2. `cases.expected_cap()` 的独立实现改为"`实测 ≥ 公式` 且 `实测 ≥ 自报` 即通过"；
  3. **D-04 的失败语义不变**（表模型自报 1/2 < 公式 3/30 仍照常 FAIL）；
  4. 组数类断言仍以产品自报上限为 oracle（H-10），两条口径叠加后 `实测 > 公式` 不再产生 FAIL。


## H-20 用例写法错：TTL 生效后写过期时间戳 / 表模型用例用树库（已修）

* **TTL-02/03/08**：用例 `set ttl to <db>.** to 1000` 之后仍以**过期/临界**时间戳写入
  （TTL-02 亚秒竞态：写 16:13:43.040 被边界 16:13:43.300 拒；TTL-03 写 1 小时前；TTL-08 写 5 秒前），
  被产品以 `607: Insertion time … is less than ttl time bound` **正确**拒绝 ⇒ 用例自伤，非产品缺陷。
  修法：新增 `_ttl_safe_now()`（= 当前 + 2×TTL + 1s，仍在 TTL 有效窗内），5 处写入改用它；
  TTL-03 原先"写过期数据"的语义改为"写有效数据后等其过期"（与用例标题一致）。
* **HA-12**：全程用 **table 方言**（`write_items`/`count_rows`/`slot_map_of`）却建在**树库 `root.pg`** 上，
  被产品以 `701: The tree model database shall not be specified in table model` **正确**拒绝。
  修法：改用 `reset_db(ctx, "table")` 的表模型测试库，`d = "table"`。
* **定性**：这两类都是 harness 自伤；产品行为正确，**不登记产品缺陷**。

## H-21b `show data regionid` 只认完整设备路径（已修）

* **实测**（在 2.0.11 集群上直接验证）：
  * `show data regionid where device=root.pgprobe.d0`    → `RegionId = 1122` ✅
  * `show data regionid where device=root.pgprobe.d0.s0` → `Empty set`（测量路径不行）
  * `show data regionid`（无 WHERE）→ `700 … mismatched input '<EOF>' expecting WHERE`
* **真因**：`RST-01` / `TTL-03` 把 `device_set()` 返回的**短名**（`pgr0`/`pge0`）直接传给
  `device_groups()`，查询必然空集；而 `device_group()` 对失败**静默返回空串**，
  于是表现为"设备→组映射全空"，极易被误判为产品缺陷。
* **修法**：4 处调用点改为 `[f"{db}.{_d}" for _d in devices]`；`pgapi.device_group` 对**短名直接留痕**，
  不再静默（`_last_error`）。

---

## H-15 / H-16 / H-22 定义补录（原文缺失，按引用点反推）

改前的正文**引用**了 H-15、H-16、H-22，却没有对应小节（`TRIAGE_full_round.md:418`、`:527`）。
全仓库检索（`grep -rn "H-15\|H-16"`）除 `HARNESS_FINDINGS.md` 与 `TRIAGE_full_round.md` 外无第三处落点
⇒ 原始条目已丢失。以下只写"引用点能支撑的边界"，**不臆造细节**；需要可执行细节时按 H-17 与下文 H-22b 执行。

| 编号 | 引用点 | 能确认的边界 | 后续处理 |
|---|---|---|---|
| **H-15** | `TRIAGE_full_round.md:57`："产品启动期已知 WARN = **H-15/H-16/H-17** 家族" | 属**产品启动/收敛期已知 WARN** 的归因家族（与 H-17"收敛期窗口 + 本轮 run 起点硬下界"同族）；本身不含可执行正则 | 实际判定一律以 **H-17** 为准；H-15 不再单独引用 |
| **H-16** | `HARNESS_FINDINGS.md:356`"收尾③ 仍报日志命中，且**模式已修好**（H-16）"、`:364`"H-16 之后仍在的窗口判定" | 是**日志归因模式表（`HARNESS_INDUCED_PATTERNS`）的一次修正**；修完模式后仍漏窗口判定，由此引出 H-17 | 模式细节无法从仓库复原；判口径以 H-24（按动作类型建表）为准 |
| **H-22** | `TRIAGE_full_round.md:418`、`:527`（"被正文引用但无定义"） | 本条在**本轮交付文档正文已无直接引用**（只有 H-22b）；规则来源是本轮任务书 | 按"条目丢失"处理；恢复需原始记录，**不得据现有材料补写** |

### H-08 定义补录（本文缺条目，定义可从历史记录复原；与 H-02 同一根因）

本文正文另有 **H-08** 的两处引用（`:99`"本条与 H-08（分摊库数口径）是同一根因的两面"、
`:158`"即 G-08/H-08 那条口径"），但改前无对应小节。定义可从 `docs/报告_TDB-367_PROACTIVE回归.md`
§5.6 的收口表复原：**上限公式的分摊库数应取"树模型 ∪ 表模型"用户库并集**（原按单方言论库计数 ⇒ 假 FAIL），
已修（selftest + 复跑）。它与 **H-02**（"上限断言曾按单一方言的分摊库数算，会假 FAIL"）是同一根因的两次记录，
可执行细节以 H-02 + `references/doc-gaps.md` G-08 为准。

## H-22b `drop database` 后 `show databases details` 返回 `-1` 被判失败（判定口径，修正后 PASS）

* **规则**：`drop database` 之后 `show databases details` **已不返回该库**，`-1` = 库不存在，
  同期的"区域去重 = 0"也是正确结果；把 `-1` 当"期望 0、实测 -1"判失败 = **harness 判定口径问题**。
* **本轮命中**：1 例 / 4 check —— `PG-EMPTY-10`（full 轮）的 `checks[0..3]`
  （`root.pg` / `root.pg_x` 已 drop：Schema/Data RegionGroup 数应为 0），四条实测均为 `-1`、去重 0。
  依据 `TRIAGE_full_round.md:55`、§4.4（319–328 行）。
* **改法**：库不存在时（`-1`）该断言应按"0 组"通过，或先判 `database exists` 再决定断言语义；
  不得把 `-1` 直接与 0 比较。

## H-23 `extra_windows` 的跨用例尾窗是死代码；收尾②兜底窗锚点错

**现象**：`DEV-12` / `SMK-05` / `TTL-03` 的 `SourceHandle$GetDataBlocksTask - failed to get data block [0, 1), attempt times: 1` 都发生在**上一用例**收尾② `started dn on …` 之后 **108–128s**（`PG-DEV-11` +128s、`PG-SMK-04` +118s、`PG-TTL-02` +108s），本用例扫描时判 FAIL。

**根因（代码级）**：

* `scripts/pgkit/cli.py:168` 每个用例都 `ctx_factory.factory()` **新建** `CompactionVerifier`，所以 `extra_windows` 永远只含本用例的窗口；`verify.py:420` 注释声称"跨用例"，实际是死代码。
* 收尾②的兜底窗是 `(sweep_started, sweep_started + CLUSTER_CONVERGENCE_WINDOW_SEC)`（`cases.py:200-226`），而 `sweep_started` 是**开始做一致性对拍**的时刻，比真正 `stopping DataNode` 早 4–5 分钟（`DEV-11`：sweep 窗 ≈19:36–19:41，停机 19:40:55，命中 19:43:20 ⇒ 窗外 2 分钟）。

**建议**：verifier 提升到 run 级（或在 `RunContext` 里存 windows 并注入），收尾②改为用**实际** `stop_epoch` / `start_epoch` 锚定 `(t-5, t+300)`。

## H-24 日志归因正则表覆盖面不足（18 例）

`HARNESS_INDUCED_PATTERNS`（`verify.py:39-92`，24 条）漏掉整整 6 族"harness 动作必然引发"的签名，这些行在窗口内却被当产品噪声：

| 族 | 签名（原文片段） | 触发它的 harness 动作 | 用例 |
|---|---|---|---|
| A 只读/恢复 | `Change system status to ReadOnly! Only query statements are permitted!`、`Current system is read-only mode. Skip active load dir scanning.` | `SET SYSTEM TO READONLY ON LOCAL` → 恢复 `RUNNING` | HA-13, HA-14, HA-03, HA-06, HA-07 |
| B CN 异步 RPC 重试 | `Failed to INVALIDATE_LAST_CACHE on DataNode`、`Failed to UPDATE_REGION_ROUTE_MAP after 6 retries`、`Failed to CREATE_SCHEMA_REGION after 6 retries`、`Failed to CREATE_DATA_REGION on DataNode`、`Timeout during CHANGE_REGION_LEADER. Retry: 0/1` | 停 1 台 DN（`HA-*`）/ 建库 | HA-01, HA-03, HA-05, HA-06, HA-07, HA-10, HA-11, HA-12 |
| C IoTConsensus 发送失败 | `DispatchLogHandler - Can not send Batch{…}`、`Interrupted when dispatching write async`、`write locally failed` | 停 DN 的瞬间 | HA-05, HA-07, HA-10 |
| D Ratis 启动收敛 | `RaftServerImpl - Failed appendEntries* 2->3#0-t1,previous=<PROTO_DEFAULT>`、`Failed to recognize N as leader for APPEND_ENTRIES`、`LogUtils … Failed appendEntries` | `create database` 后新组 bootstrap / CN 重启 | SYS-06, SWCH-05 |
| E CN 重启期 | `The current node (leader) may have been down TEndPoint(…)`、`Internal error processing openSession`、`Metadata lease is fenced`、`Cannot find IOTDB_HOME or IOTDB_CONF`、`Couldn't load the configuration iotdb-system.properties` | `RCV-*` 里 harness 主动重启 CN | RCV-06（47/48 行在窗内） |
| F 元数据/协调器 | `[LeaderBalancer] … leader cannot be selected`、`Failed to get table … when calculating the time series number`、`SYNC_TOPIC_META` 重试、`Failed to execute alter database … 525` | `drop database` / `create database` / 拒绝的 ALTER | DEV-18, OBS-02, HA-06, TIME-02, TIME-04, LIM-15 |

**建议**：按"动作类型 → 允许签名"建表（停机/启动/建库/删库/`set configuration`/只读各一族），而不是单一扁平正则列表；A/B/C/D/E 族全部收白名单，F 族按动作窗口限流。

> 连带修订：`D-10`「`[LeaderBalancer] … leader cannot be selected` 非 harness 触发」的旧结论据此改为 F 族归因
> （`DEV-18` Δ=-2s、`OBS-02` Δ=+1s 均落在 `drop database` 窗口，见 `DEFECT_CANDIDATES.md` D-10）。

## H-25 窗口 pad 太小或锚点缺失（15 例）

| 子类 | 现象 | 实测 Δ | 用例 |
|---|---|---|---|
| 节点启动收敛尾 | `启 CN/DN …（±30s）` 之后 Ratis `Failed appendEntries` / `GrpcLogAppender` 断连持续 50–64s | Δ=+50,+54,+63,+64s | RCV-01, RCV-02, RCV-04, RCV-07 |
| 库被删/重建后组销毁尾 | `删除另一模型测试库（±20s）` / `fixture 重建测试库（±30s）` 之后，对端 `GrpcLogAppender is interrupted`（组被销毁）出现在 30–92s | Δ=+30,+32,+50,+74,+92s | DEV-19, TIME-07, LIM-08, LIM-11, LIM-02 |
| 配额热加载后的内存块重注册 | `set configuration` 热加载会批量新建组，各 DN 随后重新注册同名 `Consensus` 内存块 ⇒ `MemoryManager:256 - getOrRegisterMemoryBlock failed … already exists`；命中距 `热加载` 动作 26–152s，远超 `±20s`（而且用例的**恢复**动作根本没开窗） | Δ=+26,+42,+51,+61,+144,+152s | SWCH-06, LIM-10, LIM-17, LIM-09, LIM-07, LIM-06 |

**建议**：窗口按动作类型给**不对称** pad（启动类 `+120s`、删库/建库类 `+180s`、`set configuration` 类 ±20s 且**恢复也要开窗**）；把 `_line_epoch` 命中改为"命中区间"而非单点。

> 连带修订：`D-08`「快速 drop/create 后 `MemoryManager` 记 WARN」据此**降级为 harness 归因**（本表第 3 行），
> 不再作为产品缺陷候选（见 `DEFECT_CANDIDATES.md` D-08）。

## H-26 辅助解析缺陷（4 例）

| 位置 | 缺陷 | 影响 |
|---|---|---|
| `pgapi.py:444-453 count_rows` | 多测点 `count(*)` 结果只取**第一列** | `TTL-07`：`devid=pgd0 期望 2` 实测 1 |
| `cases_ops.py:319 _replica_rows` | 期望 `raw` 键，本轮 evidence 结构无此键 ⇒ `KeyError: 'raw'` | `HA-02`、`HA-04` 直接 EXC |
| `cases_ops2.py:660-692 _effective_settings` | 依赖 `show configuration`，2.0.11 返回 `700: … no viable alternative at input 'show configuration'` ⇒ 恒 `{}` | `RST-04` 及 DFS 系列校验空转 |
| `cases_ops2.py` TTL 用例的时间戳安全边际 | 写用 `_now_ms()`，但真正应用到 DN 时已过 7.5–7.7s（`time=2026-10-17T05:10:04.334` 在 `05:10:12.836` 被判 `less than ttl time bound 05:10:11.836`，TTL=1000ms）⇒ 产品正确拒绝，删/写顺序与 TTL 值需留边际 | `TTL-02` |

## H-27 期望值与状态建模错误（11 例）

| 模式 | 具体错在哪 | 用例 |
|---|---|---|
| 硬编码显式上限 | `explicit = 4` 写死，未读产品当前上限（=5）⇒ `525`，后续 5 项级联 | LIM-15, DIS-02 |
| CUSTOM 语义 | 按"CUSTOM 停在 minNum"建模，源码是"补到 R" ⇒ 实测 60 被判失败 | SWCH-03, SWCH-04 |
| 只切一类策略 | `_one_kind_switch` 的最终交叉校验对被切换的那一类仍用**原**策略公式 | SWCH-05, SWCH-06 |
| 双写记账 | `_step` 对同一设备先写 SCHEMA 再写 DATA，第二个 `_step` 把 `\|P\|` 记 1 但无新 slot ⇒ `G+\|P\|` 虚高 | SWCH-05, SWCH-06, SWCH-11 |
| 断言错类 | `SWCH-11` 只切 DATA，却用 AUTO 公式断 SCHEMA | SWCH-11 |
| 库存量 vs 实时配置 | 用热加载后的 `min=5` 断言，而该库创建时 min=2（`ClusterSchemaInfo:748-771` 读库存量） | MIN-06 |
| 简化公式 | 期望用 `min(K, 上限)`，漏掉 `minNum` 项：`min(30, max(min(2,1+1),1)) = 2` | HA-05 |
| K 少算 | `root.pg.multi` 占 1 槽未计入 K（1+4=5，用例按 4 断言） | REB-13 |
| 表模型判据 | 对表模型断 `SHOW TIMESLOTID`（-1 是哨兵） | LIM-10 |

## H-28 前置缺失 / 断言自相矛盾（7 例）

| 用例 | 缺陷 |
|---|---|
| `DEV-15` | 用例从未 `create table pg.tb`（靠上一用例残留表）⇒ `550: Table 'pg.tb' does not exist.` |
| `OBS-06/07/08` | 三个用例都在 `re.search` 处崩：`NameError: name 're' is not defined`（`cases.py` 的 847 / 960 / 1025 行）。**当时缺 `import re`；跑批后 20:03:55 已补**（见 H-30），当前工作副本可直接重跑。这三个用例本是 D-05 的判定实验，**优先重跑** |
| `HA-09` | `create database root.pg.sub` 非法（`501: root.pg has already been created as database`） |
| `PRV-07` | `_setup_user(system=False)` 不授任何权限，却断言普通用户能看到 `root.pg` |
| `HA-13` | 收尾断言 `min(max(before,1),ceiling)=1` 与本用例 `只增不减 1→4` 自相矛盾 |

## H-29 收尾① 在"采样面失效"时不会 fail-fast

**现象**：`HA-01` 1800s 内每次都是 `sync lag: no series yet (empty result)`，最后仍给一条"未归零"的 FAIL（`last samples: []`）。`verify.py:362`（`if not values: continue`）与 `:366`（`worst = max(values)`）只在**有值**时更新 `worst`；`values` 为空时既不 fail-fast 也不区分"指标面没数据"与"lag 真的不为 0"。

**建议**：连续 N 次（如 6 次）`values` 为空 ⇒ 直接 `INVALID` 并附抓取错误（`_query_prometheus` / `_query_metrics_labeled` 的异常信息），而不是烧满 1800s。

> 本轮后果：`PG-HA-01` 因此被记为 **INVALID**（旧口径下会被记成"产品 sync lag 不归零"的假 FAIL），
> 详见 `REPORT.md` §5。

## H-30 代码在跑批后被改，但没有版本标记（"已修但仍记 FAIL"）

**证据（mtime 对齐轮次时间）**：

| 事实 | 时间 |
|---|---|
| 全量轮 `pg_full_iot_final` 起止 | 2026-10-16 **16:06:04 → 19:50** |
| `scripts/pgkit/cases.py` 最后修改 | 2026-10-16 **20:03:55**（两轮之间） |
| resume 轮 `pg_iot_resume` 起 | 2026-10-16 **20:49:50** |

⇒ 全量轮里 `OBS-06/07/08` 的 `NameError: name 're' is not defined` 在**跑批后 14 分钟**就被补上了（补丁即 `cases.py:22` 的 `import re`）；当前工作副本已无此问题，这三个用例只需重跑，**不需要再修**。

**风险**：`pgkit/` 不在 git 里（`git status` 报 `not a git repository`），跑批用的代码版本只能靠 mtime 推断；本轮除 `cases.py` 外，其余 `pgkit/*.py` 的 mtime 都早于全量轮起点（`cases_ops2.py`/`pgapi.py` 14:21、`verify.py` 09:09、`cases_lim.py` 10-14），所以本报告引用的行号对两轮都成立。

**附带发现**：`cases.py` 头部的 docstring 仍写"占位模块，注册表为空／没有任何 PROACTIVE 用例体"，但文件里已有全部用例体（1087 行起登记 `CaseSpec`）—— 说明 docstring 未随实现更新，容易误导后来者判断"用例没写"。

**建议**：① 跑到一半改代码必须先落 `runs/<ts>/code.sha256`（或 `git rev-parse`）并在 `run.log` 头打印；② 跑批前 `python -m py_compile scripts/pgkit/*.py` + `ruff --select F821`（`re` 这类未定义名一次就能扫出）；③ triage 报告里对每个 case 标注它所用的 code 版本。

---

> **编号来源说明**：H-22b、H-23…H-30 来自本轮 217 例全量分诊
> （`../TRIAGE_full_round.md` §1.2、§4.6、§5），按原文录入，仅补证据路径与行号锚点；
> H-15/H-16/H-22/H-08 的补录按引用点反推（见上文"定义补录"小节）。

### H-31 `select count(*)` 在 2.x 是"每测点一列"，不是行数
- 现场：UPG-13 断言"新测点可查（行数 1 -> 1）"在 2.0.11 上 FAIL；实际输出为单行多列
  `count(s_new) | count(s0) | count(s1) | count(s2)`，数据完全可查。
- 根因：用例用 `count_rows(...)`（行数/列值最大值）比较"新增测点前后"，而新增测点不会改变任何
  单测点的 count，恒为 1 → 断言恒 FAIL。
- 修法：直接 `select count(<新测点>) from ...` 并解析为 1；不再用 count_rows 比较大小。
- 影响：仅 UPG-13；同类写法在其它用例中若需要"新测点可见"必须用同一口径。
- 复跑：`pg_upg20_upg13b` → PASS。

### H-32 日志卫生的两类"重试噪声"WARN（分类记录，不放行）
- L-1 `AsyncRequestManager:147`：leader 迁移目标不可达（停机/切换窗口）后固定重试 1 次放弃。
- L-2 `FragmentInstanceDispatcherImpl:545`：查询分片派到无该 region 副本的 DN，WARN 后转投其它节点。
- 处置：仅在报告中分类与计数，**不修改 verdict、不进白名单**；若产品未来降级为 DEBUG 或首跳不再 WARN，可整体消失。

## H-36 升级族的日志窗口必须按「版本横幅」分段

**现象**：升级族的收尾③（日志卫生）扫的是 `DB_DIR/logs/*all*.log`。一次 1.3→2.0 升级里，同一个
`log_datanode_all.log` 先被**旧版本**写入（停机阶段的 Shutdown-Hook、Ratis 中断、压缩线程终止…），
随后被**新版本**接着写。若窗口起点早于新版本启动，旧版本停机行会被记到被测版本头上 → 误判。

**判据**（可执行、不放宽）：
1. 窗口下界 = 「**当前版本（`cfg DB_VERSION`）的第一条 `Starting IoTDB <ver>` 横幅**」的 epoch，
   且该横幅之前必须出现过**别的版本**的横幅；取各节点中最早的一个；
2. 只在升级族启用（conf 含 `PG_UPGRADE_FROM_TARBALL` / `PG_UPGRADE_TO_TARBALL`），
   非升级族窗口不变——HA 族"用例内重启节点"也会产生新横幅，绝不能让窗口跟随前移；
3. 找不到边界时**不改变**窗口（`None` ⇒ 不下界），绝不因为"没找到边界"放宽；
4. 下界只排除**旧版本**行，不排除新版本行（新版本后续重启产生的 WARN 仍在窗口内）。

**实现**：
- `verify.banner_floor_from_text(text, target_version) -> int | None`（纯函数，离线可测）；
- `CompactionVerifier.upgrade_floor_epoch(target_version)`（逐节点抓 `Starting IoTDB` 横幅，取最早）；
- `cases.py` 收尾③：升级族把 `since = max(since, floor)`，并 `ctx.note` 记下下界时间；
- `selftest.py` +6 条：有旧版本横幅时取目标版本第一条、二次启动不改下界、只有单一版本不下界、
  空文本不下界、以及"下界不排除新版本"。

**实证（升级后的干净集群，dn@11.101.10.10）**：
```
下界[2.0.11-SNAPSHOT] = 2026-10-20 17:25:46   ← 1.3.7 横幅之后的 2.0 首次启动
下界[1.3.7-SNAPSHOT]  = None（不下界）        ← 跑在旧版本上时窗口不变
```

**边界澄清**：旧版本停机行只是**不计入新版本判据**，不是"丢弃"。它们仍应作为升级前的基线留档
（若其中出现数据损坏/落盘异常，属迁移正确性问题，要单独看）。

### H-37 测点级 `count(*)` 在 2.x 必然空集（20 处调用点）
- 现场：10 个用例的"写入后行数 = N"断言在 2.0.11 上返回 `-1`（空集），一度被当作产品缺陷 D-05。
- 根因（2026-10-20 干净集群实锤）：2.x 的 `count(*)` 语义是"FROM 路径下**各测点**的行数"（H-31）。
  用例把 1.x 口径直接搬过来：
  ```sql
  select count(*) from root.d05.dev1.s1   -- 测点路径下没有子测点 -> Empty set
  select count(s1) from root.d05.dev1     -- 正确写法 -> 1
  ```
  同一份数据下 `select s1 from root.d05.dev1` 有值、设备级 `count(*)` 有值，
  说明**数据可读**，只是聚合的 FROM 路径选错层级。
- 修法：`pgapi.py` 新增 `PgApi.count_series(target, ...)` —— 目标写成 `<db>.<device>.<sensor>`，
  内部改写成 `select count(<sensor>) from <db>.<device>` 并取第一列数值；
  已把 20 处 `count_rows(f"<db>.<device>.<sensor>")` 全部替换为 `count_series(...)`
  （`cases.py` 1 处、`cases_msr.py` 19 处），`selftest` 764 项仍全过。
- 影响：D-05 由"已确证产品缺陷"**撤销**为 harness 适配问题；
  另建议 RN 补一条 1.3→2.0 兼容性提示（同一个 SQL 在 1.3 返回行数、在 2.0 返回空集）。
- 复跑（干净 3C5D，2.0.11）：`PG-MSR-01`（13 check）、`PG-TIME-01`（13）、`PG-MSR-13`（13）、
  `PG-TIME-12`（111）**全部 0 失败**；结果见 `results/exp_d05_fix1`、`results/exp_d05_b`。

### H-38 组数前置断言用纯公式当 R（3 例）
- 现场：`PG-DIS-03`、`PG-RCV-05`、`PG-RCV-06` 在 2026-10-20 夜间全量轮失败，
  签名统一为「前置：… SchemaRegionGroup 数应为 1，实测 2」。
- 根因：这三个前置用 `_cap()`（**纯源码公式**）当 R，再取 `min(2, R)`；
  而产品为每个库保留**单调不减**的历史上限（H-19 已实证），
  库重建/改配额后公式值可能低于已存上限，于是 R 被算成 1，而实际组数是合法的 2。
  同类问题早先已在组数断言里修过（`_group_r` 专门做 `max(公式, 自报上限)`），
  但这三处前置漏改。
- 修法：`_cap` → `_group_r`（`cases_lim.py` 中 DIS-03 1 处、RCV-05 2 处、RCV-06 2 行）。
  `selftest` 764 项仍全过。
- 影响：不是产品缺陷；这三例应复跑后转 PASS（全量轮结束后执行）。

### H-39 停机/启动窗口的两条噪声签名（`PG-HA-01`）
- 现场：`PG-HA-01`（停 1 DN 后写 3 个新 slot）两次因"收尾③ 日志异常"失败：
  1. `ERROR IoTConsensusRPCServiceProcessor:97 - fail to sync logEntries because system is read-only`
     —— 13:19:28.963，与 harness「停 DataNode 11.101.10.9」（13:19:28）**同秒**；
     该 DN 已切 read-only 停机流程，仍收到 leader 的 logEntries 同步请求，按设计拒绝。
  2. `WARN IoTDBInternalLocalReporter:178 - Failed to update the value of metric ... code:305 Interrupted`
     —— 08:49:36，与「停 DataNode」（08:49:36）同秒；本地指标上报线程被 shutdown hook 打断。
- 处置：两条都加入 `HARNESS_INDUCED_PATTERNS`，**仍要求落在 harness 动作窗口内**才归因
  （`_attribute` 的既有纪律不变）；窗口外同样的行仍判 FAIL。每条都注明了动作与时刻。
- 验证：`PG-HA-01` 复跑 **PASS（13/13）**；`selftest` 764 项全过。
- 反例保留：`DataNodeMemoryConfig:794 - table_query_device_entry_batch_size_in_bytes ... exceeds
  the maximum RPC payload` 是**启动期配置自检告警**，selftest 明确要求它必须报出，
  因此 `PG-HA-09` 保持 FAIL、只作"环境档位噪声"记录，不进白名单。

### H-40 1.3 源的 license 必须逐机种入（否则永远激活不了）
- 现场：1.3.7 `< 2.0.10.1` 不接受内置 `03` 试用码，需 `00/01` 正式码；
  而正式码按**每台机器自己的 node_uuid** 签发，`activation/license` 与 `DB_DIR/.env`
  必须成对匹配。
- 旧行为：`ensure_license` 只接受单个 `LICENSE_SRC` 文件并复制给**所有**机器，
  用某一台的 license 铺满 5 台 ⇒ `SHOW CLUSTER` 恒 `UNACTIVATED`，升级族整体 SKIP。
- 处置：`LICENSE_SRC` 支持**目录**形态——每台机器取 `<dir>/license` → `activation/license`、
  `<dir>/.env` → `DB_DIR/.env`；`LICENSE_CODE` 留空（不提交 2.0 的 03 码）。
- 验证：1.3.7 集群 8 节点全部 `ACTIVATED`，pre 阶段 7 例真实跑起来（5 PASS）。

### H-41 post 阶段启动可能撞上 1.3 残留进程（锁占用）而误报"没起来"
- 现场：`Failed to lock storage .../confignode/consensus/47474747-.... The directory is already locked`
  → `_wait_seed` 等 10 分钟后报 `seed ConfigNode 11.101.10.9 did not come up`；
  实际上 2.0 进程随后自行起来（人工确认 8 节点 `2.0.11-SNAPSHOT / 029a333 / ACTIVATED`）。
- 诱因：本轮此前用手工 `sudo` 起过 1.3 节点，`assert_stopped` 的 java 进程计数没覆盖到
  root 进程/时序竞争；另外升级后口令仍是 1.3 的 `root`，就绪探测若用 2.0 口令会得到 801。
- 建议修复：`assert_stopped` 后再做一次"端口 + `data/**/.iotdb-lock`"双确认；
  `_wait_seed`/`wait_sql_ready` 把 `801 Authentication failed` 视为"已应答"（服务已起）。
- 业务结论不受影响：升级数据本身正常（post 9/9 PASS）。

### H-42 benchmark 编排的三个真问题（5 例测点规模用例全 SKIP 的根因）
1. **`conf/bench_template.properties` 第 1 行中文注释里的 `{占位符}`** 被 `str.format` 当占位符
   → 每次调用都 `KeyError: '占位符'`，5 个 bench 用例（MSR-09/11/15/17/19）全部 SKIP。
   修：注释里的花括号转义成 `{{占位符}}`。
2. **配置与输出写到了本地路径**：`bench_run` 把 `config.properties` 和 `bench_<tag>.out`
   指向构建机的 `out_dir`，而 benchmark 在客户端机（`PG_BENCH_SSH`）执行 →
   重定向目录不存在、benchmark 从未真正启动，harness 空等 `duration+600s` 才放弃。
   修：在客户端机 `/tmp/pgbench_<tag>/` 写配置与输出，结束后把 `bench.out` 与
   `config.remote.properties` 取回本地证据目录。
3. **`IS_CLIENT_BIND` 未按设备数选择**：默认 client-bind 要求"客户端数 ≤ 设备数"，
   而单设备档位配了 1 schema + 2 data 客户端 → `ConfigDescriptor` 报错退出。
   修：`device_number >= 1 + data_client_number` 时用 client-bind，否则 server-bind。
4. 附带：`LOOP=100000000` 让 benchmark 永远跑不完（`TEST_MAX_TIME` 不拦写入），
   改为按"设备×测点/批大小"估算的有限操作数。

* 进展（17:11）：benchmark 已完整跑完并打印
  `INGESTION 903 90300000 0 0 1369974.90`（a>0、c=0、d=0），**写入成功**；
  原先的 `507: Fail to insert measurements` 已定位为"边写边 drop 库"的竞态
  （服务端原文 `insertTablet failed because Some other task is deleting database root.pg`），
  修法：`bench_run` 启动前先 pkill 残留 benchmark，跑完再 pkill。
* 另修两处：`INGESTION` 行尾还有吞吐列（`... 0 0 1369974.90`），正则不再要求行尾锚点。
* 仍待解决：用例侧"数据可见性"校验——1 万测点只查到 1000 个 series，
  且对样本 series 执行 `count(*)` 返回 Empty set；需确认是 `show timeseries` 默认
  返回 1000 行（harness 测量口径）还是 benchmark 只注册了 1000 个测点。

### H-43 benchmark 用例从"永远 SKIP"到"功能断言全绿"的六处修复
1. `conf/bench_template.properties` 注释里的 `{占位符}` 被 `str.format` 当占位符 ⇒ `KeyError`；
2. 配置/输出写在构建机路径，benchmark 在客户端机执行 ⇒ 改为 `/tmp/pgbench_<tag>/` 并回传证据；
3. `IS_CLIENT_BIND` 未按设备数选择 ⇒ 单设备档位自动 server-bind；
4. `LOOP=100000000` 永不结束 ⇒ 按工作量估算（大测点档 12 次操作）；
5. `INGESTION` 行尾有吞吐列，正则锚定行尾匹配不上 ⇒ 只取前 4 个整数；
6. `507` 实为"边写边 drop 库"竞态 ⇒ benchmark 启动前先 pkill 残留客户端。

另修两处判定口径：
* `SHOW TIMESERIES` 默认只回 1000 行 ⇒ series 总数改用 `count timeseries <db>.**`；
* 2.x 对**测点级路径**执行 `count(*)` 返回空集 ⇒ 样本行数改用 `count(<sensor>) from <db>.<device>`；
  并给 300 s 收敛轮询（9000 万点落盘后可见性滞后 4–5 分钟）。

**结果**：`PG-MSR-09` 的 12 项功能断言全绿
（`INGESTION a=903 b=90300000 c=0 d=0`、slot=1、Data 组=1、Schema 组=1、样本 series 行数=903）。
仅剩「收尾③ 日志异常」未过，命中两类噪声：
* `dn: WARN ratis LogUtils - Failed appendEntries ...`（高写入负载下的 ratis 重试）；
* `dn: WARN CommonConfig:952 - Change system status to ReadOnly`（收尾②停 DN 的 Shutdown-Hook 行）。

### H-44 SWCH-08「设备→RegionGroup 映射不可见」实为短名问题
`show data regionid where device=…` 只认完整设备路径；用例传的是短名 `pgd0`，于是四个设备
全部返回空串并 SKIP。修法：用例内把设备名补成 `<db>.<dev>` 再查（与 cases_ops2 的写法一致）。

### H-45 PRV-02/06 的 ``grant system to user`` 语法错误
`IoTDBSqlParser.g4:1228` 规定 `GRANT <privileges> ON <prefixPath> TO USER <user>`，
旧实现缺 `ON`，必然 `700: no viable alternative at input 'grant system to'`；
`REVOKE` 同理（`:1248`）。修法：`grant/revoke system on root.** to|from user <user>`。

### H-45b HA-08 的「只读 DataNode」档位其实有产品语句
`IoTDBSqlParser.g4:1369` 提供 `SET SYSTEM TO READONLY | RUNNING [ON LOCAL|CLUSTER]`，
用它就能造只读副本：HA-08 改为在停机 DN 之外再挑一台置 READONLY、写入断言、finally 恢复 RUNNING。

### H-46 DEV-21 上限口径漏了公式第三项 ``allocated``
`ClusterSchemaManager.calcMaxRegionGroupNum` 的公式是
``max(min, ceil(weight×resource/(databaseNum×rf)), allocated)``；`_caps` 只比前两项，
先写 A 库再建 B 库时产品自报 SCHEMA=2、公式=1 ⇒ 被误判为"档位不符"而 SKIP。
修法：按 ``max(公式, 已分配组数)`` 比对并把有效上限返回给后续断言。

### H-47 50 万测点档位 benchmark 客户端 OOM
`-maxheapsize 1G` 下 50 万测点直接 `java.lang.OutOfMemoryError: Java heap space`；
改为 `-heapsize 1G -maxheapsize 8G`。

### H-50 收尾②对「单设备几十万测点」的 `count(*)` 会打挂服务端
`select count(*) from root.pg.g_0.d_0`（50 万测点）直接 `query failed`，收尾②两遍捕获永远
等不到一致结果 ⇒ 判 FAIL。修法：对拍查询改用**单个测点**的计数（先 `show timeseries … limit 1`
取一条，再 `select count(<sensor>) from <db>.<device>`）。`PG-MSR-19` 因此转 PASS。

### H-48 DFT-01/02 的「conf 不含策略键」前置不成立（已修）
`region_group_knobs()` 在 `PG_OMIT_POLICY_KEYS=true` 时确实会剔除两个策略键，但 deploy
沿用了 DB_DIR 里**已存在**的 `iotdb-system.properties`（早前档位写入的），键仍在文件里，
前置检查因此失败。修法：新增 `Cluster.remove_system_properties()`，omit 档位部署时从每台节点的
文件里**删除**这两个键；改后 DFT-01/02/SMK-01 全部 PASS。

### H-45c `SET SYSTEM TO READONLY` 必须带 `ON LOCAL`
不带 `ON` 时语句按 CLUSTER 派发，会尝试切换到**所有** DataNode；HA-08 期间有一台已停机，
派发到它就返回 `1007 Failed to SET_SYSTEM_STATUS on DataNode`。只切当前节点要写 `ON LOCAL`。

### H-49 50 万测点档位撞到 `wal_entry_size_limit_in_byte`（默认 32MB）
`PG-MSR-19` 重跑（堆已放大到 8G）后 benchmark 报
`620: The WAL entry size 41555678 exceeds wal_entry_size_limit_in_byte 33554432`：
单设备 50 万测点的一次 aligned 写入把整行 50 万列塞进一条 WAL 记录，条目约 41.5 MB。
这是产品的可配置上限，不是缺陷。已把该键纳入 harness 的 knob 白名单
（`PG_PROP_KEYS` / `EXPECTED_PROP_KEYS` / `HOT_RELOAD_KEYS` 子集断言），master conf 设
`PG_WAL_ENTRY_LIMIT=134217728`，改后 `PG-MSR-19` 的 benchmark 段通过。

### H-51 3C4D 是可构造的（不用在线加减 DN）
只要换一份 **节点清单** 再重部署即可：`conf/nodes_3c4d.conf`（3 个 cn + 4 个 dn，去掉 .6）配
`conf/cluster.pg_3c4d_iot.conf`（`NODES_FILE`/`DB_DIR=/data/mpp_test/pg_3c4d`/`DEPLOY_HOSTS` 四台）。
`Config.dn_hosts` 直接由清单派生，公式与用例期望自动按 dn=4 计算，无需改代码。
实测：3C4D 上限 Schema 4 / Data 48，3C5D 为 5 / 60，DN=3 推算 36 —— 与公式完全一致。
跑完 teardown 再按 master conf 部署即回到 3C5D。

### H-52 Disabled 补组族：SQL 面看到的是逐 Region 的 `unknown`，不是聚合 `Disabled`
`RegionGroupCache.java:129-149`：弱一致下 `runningCount >= 1` 为 Available，否则聚合 Disabled；
但 `SHOW REGIONS` 在副本 DN 停机后只给 `unknown`（甚至不再返回副本行）。夹具据此改为：
"副本全停 + 状态 ∈ {disabled, unknown}"（副本不可解析时按停机前副本集合）即认定聚合 Disabled。

### H-53 DIS-04 的 R 要收敛到 1 才能"单组即达上限"
R = ceil(dn / (库数 × rf))，因此按实际 `dn/rf` 自动补足参与分摊的普通库数量（原来写死 3 个库，
在 dn=5、rf=1 时 R=2，与"单组即上限"矛盾）。

### H-54 表模型没有 TTL 语句（实测）
表方言下 `SET TTL` / `SHOW TTL` / `UNSET TTL` 全部被解析器拒绝（`700 mismatched input 'ttl'`），
TTL 语法只存在于树模型（`IoTDBSqlParser.g4:343` 的 setTTL 用 prefixPath）。TTL-06 改为负向断言 +
树模型对照，两个方向都通过。

### H-55 上限分母是"树+表两模型普通库总数"，残留库会把 R 压到低于用例前提
MIN-04 前置要 R≥3，但前面用例残留的库让 R=2 ⇒ 先清掉其它用户库再算上限（`_solo_tree` 只清表库，
清不掉其它树库）。

### H-56 「全部 Schema 组 Disabled」是可测的，而且有意义（DIS-02 已成 PASS）
先前的判断（"Schema 全挂 ⇒ 元数据不可用 ⇒ 不可测"）**不成立**：Schema 组是**按库**的，
ConfigNode 的元数据服务并不依赖某个库的 Schema 组在线；补组正是这类场景的**自愈动作**。
用 `SCHEMA_REPLICATION_FACTOR=1` 档位（`conf/cluster.pg_dis02_iot.conf`）即可稳定构造：
停掉唯一副本所在 DN ⇒ 该库 Schema 组全 Disabled ⇒ 新 slot 元数据请求补 1 组（G 1→2、R=15）、
写入成功 ⇒ DN 恢复后组回到 Running。rf=3 时因需打掉每组多数派，≤2 台 DN 覆盖不了两组，
那才是当时 SKIP 的真实原因（构造手段不足，不是场景无意义）。

### H-57 全量跑批必须"每例前清场用户库"，否则上限分母被前序用例污染
H-55 只修了单个用例（MIN-04）。全量跑到第 30 例时暴露出系统性问题：上限公式的分母是
**全部普通库数**（`ClusterSchemaManager.java:532`），前面 30 条用例各自建库、留下的库没人清，
分母被撑大 ⇒ 新库的上限直接落到最小值 `R=(1,2)`，于是"按 slot 扩组"的断言全部落空。
实测证据（同一 build、同一条用例）：

| 场景 | 表库/树库自报上限 | 4 个 slot 后的 Data 组 |
|---|---|---|
| 残留 30 个库（污染） | (1, 2) | 2 |
| 清场后（干净） | (3, 30) | 4 |

所以在 `run_cases()` 里加了**每例开跑前 `drop_user_dbs()`**（升级族 `PG-UPG*` 例外，必须保留
pre 阶段建的库）。修完 PG-DEV-15 / PG-SMK-05 立刻由 FAIL 转 PASS ⇒ 那些 FAIL 是**测量污染**，
不是产品缺陷（这一点我先前误判过一次，靠 LIM-21 的实测上限才发现）。

### H-58 表模型"单行 20 万列"的 benchmark 写入在本环境不可用（三层限制）
MSR-18（表 1×20 万）/ MSR-20（表 1×50 万）连续撞了三堵墙：

1. 客户端 thrift 帧上限：`Frame size (181814256) larger than protect max size (67108864)`
   ⇒ benchmark 配置项 `IOTDB_THRIFT_MAX_FRAME_SIZE`（conf 键 `PG_BENCH_FRAME_SIZE`，设 512MB），
   服务端同侧是 `dn_thrift_max_frame_size`（conf 键 `PG_THRIFT_MAX_FRAME`）。
2. 单次写入超时：放大帧后能发出去，但 181MB 的 insertTablet 撞 benchmark 的
   `WRITE_OPERATION_TIMEOUT_MS`（默认 120s）⇒ `java.util.concurrent.TimeoutException`
   （conf 键 `PG_BENCH_WRITE_TIMEOUT_MS`，设 600s）。
3. 这一个大 region 把全集群 syncLag 拖到 2600s+ 且不收敛，会污染后续用例。

结论：表模型大列宽档改走 **SQL 单条 DDL 声明 N 列 + 写 1 行**
（`_big_table_chunked`），不再用 benchmark；不变式"测点数不增加 series slot"仍被覆盖。

### H-59 表模型 INSERT 不会自动建列（616），列必须由 DDL 声明
`insert into db.tb(time, devid, s1) values(...)` 在列未声明时返回
`616: Unknown column category for s1. Cannot auto create column.`——
所以"分块写入自动扩列"的思路不成立；正确做法是一条 `CREATE TABLE ... (devid STRING TAG, s0..sN FLOAT FIELD)`
一次性声明（实测 2 万列 DDL 0.06s 建完）。另外这类超长语句（>40KB）会撞 ssh 单参数上限
（`OSError: [Errno 7] Argument list too long`），`remote._sql_once()` 已改为长语句走 stdin。

### H-61 大测点库 drop 后 CN 删区超时 ERROR：是 harness 清场的级联后果（观察项）
H-57 的"每例前清空用户库"在**大测点档位之后**会触发 CN 的删区风暴：
`Failed to DELETE_REGION on DataNode ...`（ERROR）+ `Failed to DELETE_REGION after 6 retries`（WARN），
紧跟着 `Deleting regions costs 60064ms`，然后重新发起删除并成功。

- 触发条件：上一例在单库里写了 1 万~50 万测点 ⇒ region 的元数据极小但**删区要逐条清理 schema**，
  单次 RPC 超时 ⇒ CN 重试。
- 时间相关性（实测）：清场动作 `T`，ERROR 出现在 `T+71s`（MSR-11 01:45:14 → 01:46:25；
  MSR-13 02:27:53 → 02:29:04），即**必然落在清场窗口内**，而与用例自身逻辑无关。
- 处置：`HARNESS_INDUCED_PATTERNS` 增 `Failed to DELETE_REGION`，清场动作窗口 pad 由 10s 放宽到 240s。
- 仍留观察项：删区耗时 >60s 本身反映"大 schema 库下线慢"，每轮收尾都会出现，属于产品侧性能观察，
  不判 FAIL（删除最终成功、副本对拍一致）。

### H-62 表模型大测点档（10 万/20 万/50 万列）统一走 DDL 路径
MSR-10/12 与 MSR-18/20 同类：表模型 benchmark 的 `insertTablet` 是"一行 N 列"，
10 万列 ≈90MB、20 万列 ≈181MB。实测三种失败：
- 帧上限：`Frame size ... larger than protect max size (67108864)`（MSR-18）；
- 写超时：`302: Fail to send plan node ... TimeoutException`（MSR-12）；
- 表定位失败：INGESTION 成功但 `show tables from pg` 空集（MSR-10，benchmark 建库/建表与查询口径不一致）。

四处（MSR-10/12/18/20）现已统一为 `cases._big_table_chunked()`：一条
`CREATE TABLE ... (devid STRING TAG, s0..sN FLOAT FIELD)` + 写 1 行 + 组数断言，
既覆盖"测点数不增加 series slot"的不变式，也不产生巨帧/巨 region/长时间 syncLag。

### H-63 停机窗口内"打不到已停节点"的 WARN 应归因到 harness，而不是普通窗口
HA-11（停 1 DN 后继续按 slot 扩组）收尾③ 命中 3 条 WARN：

    FragmentInstanceDispatcherImpl:637 - can't execute request on node TEndPoint(ip:11.101.10.9,...),
        error msg is java.net.ConnectException: Connection refused, and we try to retry
    FragmentInstanceDispatcherImpl:618 - can't execute request on node  ... in second try
    QueryExecution:262 - error when executing query. no detailed failure reason in QueryStateMachine

三条指向的都是**用例自己停掉的那台 DataNode**（`11.101.10.9`），是"路由里还有已停节点 ⇒ 连接被拒 ⇒
重试到存活副本"的正常过程。处理方式：新增 `NODE_STOP_INDUCED_PATTERNS`，**仅当窗口原因里含"停"**
（即 `_stop_nodes` 记录的停机窗口）才允许归因；普通操作窗口下这些行仍判异常，不会把真实查询错误吞掉。

### H-64 升级 pre 阶段（1.3 集群）的日志异常只记录，不计入 2.0.11 判定
UPG-01..07 跑在**升级前的 1.3 集群**上，用途是记录"升级前基线"。收尾③ 曾把 1.3 侧的
`o.a.ratis...AppendLogResponseHandler: Failed appendEntries` 与
`FragmentInstanceDispatcherImpl` 派发 WARN 判成 FAIL —— 那是**旧版本**的行为，
不是被测版本（2.0.11）的判据。

处置：`closing_triad` 里当 `detect_v13(ctx)` 为真且 `PG_UPG_PHASE=pre` 时，③ 改为
"仅记录"（逐条仍落 `evidence/log_findings.txt`），断言名写明不计入 2.0.11 判定；
**post 阶段（2.0 集群）仍然严格判 FAIL**。复验：`pg_upg13_pre2` 批 UPG-01..07 全 PASS。

至此 216 例全部有判定：**PASS 212 / FAIL 4（全为 TDB-862）/ SKIP 0**。
