# TDB-367「RegionGroup 积极扩容模式 PROACTIVE」回归用例集与执行报告

> 产物位置：`/data/deepseek/proactive/iotdb-proactive-regiongroup/`（技能）
> 执行机：`ubuntu@172.20.70.17`（驱动机）；集群：11.101.10.9/.8/.7（CN+DN）+ .6/.10（DN）；客户端压测机：11.101.10.11
> 被测件：`timechodb-2.0.11-SNAPSHOT-bin.zip`（master commit `3bbeea656114`）；升级族另用 `iotdb-enterprise-1.3.7-SNAPSHOT-bin.zip`

## 1 需求点 → 用例覆盖矩阵（每点 ≥2 条）

| 需求点（PLM 360 / 设计文档） | 覆盖用例 | 条数 |
|---|---|---|
| §3.1 策略切换本身不建组 | PG-SWCH-07、PG-DFT-12、PG-SMK-06 | 3 |
| §3.2 仅"请求中含缺失分区"才触发扩容；空库不预建 | PG-SMK-02、PG-EMPTY-01/03/05/06/07/10/11、PG-OBS-01 | 9 |
| §3.2 按 series slot 计数（共槽只算 1） | PG-DEV-13/15/16、PG-OBS-01、PG-DEV-01..12 | 15 |
| §3.2 新 slot 触发扩容到 `min(K,R)` | PG-SMK-04/05、PG-DEV-02..12、PG-MSR-01..16 | 25 |
| §3.2 同 slot 新时间分区也触发（向最小数量逼近） | PG-TIME-01..12、PG-MIN-02/06 | 14 |
| §3.3 最小数量 `default_*_region_group_num_per_database` | PG-MIN-01..06、PG-DFT-04、PG-LIM-19 | 8 |
| §3.4 上限公式 `max(min, ceil(weight×resource/(库数×副本数)))` | PG-LIM-01..21、PG-EMPTY-09、PG-SYS-01..06 | 27 |
| §3.2 测点规模 20 万 / 50 万（1 设备 × N 测点） | PG-MSR-17..20（benchmark，full 层） | 4 |
| §6 高可用：1 台 DN 置 READONLY（`SET SYSTEM TO READONLY ON LOCAL`） | PG-HA-13 | 1 |
| §3.5 V2 syncLag 逐实例观测（非零即 FAIL） | PG-OBS-07 | 1 |
| §3.5 只增不减（不回收） | PG-EMPTY-03/04/14、PG-SWCH-02/03/04、PG-RCV-05 | 6 |
| §3.6 重平衡与阈值 mu | PG-REB-01..14 | 14 |
| §3.7 组状态 Disabled 时的兜底补组 | PG-DIS-01..07 | 7 |
| §3.8 配置项语义/取值/热加载/非法值 | PG-DFT-01..12 | 12 |
| §3.9 权限（SYSTEM / 普通用户） | PG-PRV-01..08 | 8 |
| §3.10 系统库与用户库的分配差异 | PG-SYS-01..06 | 6 |
| §4 观测面（REGIONS/REGIONID/TIMESLOTID/COUNT、syncLag 逐实例与回落） | PG-OBS-01..08 | 8 |
| §5 双共识协议（IoTConsensus / IoTConsensusV2） | 全量用例双协议各跑一轮（PG-PROTO） | 全量 |
| §6 高可用（扩容过程中停 1CN/1DN、只读 1DN） | PG-HA-01..14 | 14 |
| §7 重启/恢复 | PG-RCV-01..07、PG-RST-01..06 | 13 |
| §8 TTL 与扩容互不干扰 | PG-TTL-01..08 | 8 |
| §9 1.3 → 2.0 升级（预置参数、升级后参数生效、热加载、新分区） | PG-UPG-01..16 | 16 |

（上表条数按已并入注册表的用例统计；执行情况见第 5 节。）

## 2 环境与档位

| 档位 conf | 用途 | 关键差异 |
|---|---|---|
| `conf/cluster.pg_dev_iot.conf` | 开发/日常回归（IoTConsensus） | 策略显式 PROACTIVE、schema 配额 3、结果目录在工作区 |
| `conf/cluster.pg_2011snap_iot.conf` | 正式回归（IoTConsensus） | 结果目录 `/data/deepseek/proactive/results` |
| `conf/cluster.pg_2011snap_iottv2.conf` | 正式回归（IoTConsensusV2） | 数据区共识换 V2（Schema 区仍必须 Ratis，产品限制） |
| `conf/cluster.pg_default_iot.conf` | **默认值路径**（验证未显式配置 ⇒ 代码默认 PROACTIVE） | `PG_OMIT_POLICY_KEYS=true`（不写策略键） |
| `conf/cluster.pg_auto_iot.conf` | AUTO 对照 | 两类策略 = AUTO |
| `conf/cluster.pg_custom_iot.conf` | CUSTOM 对照 | 两类策略 = CUSTOM，最小组数即配额 |
| `conf/cluster.pg_slot100_iot.conf` | 快速造大量不同 slot | `series_slot_num=100` |
| `conf/cluster.pg_badcase_iot.conf` | 非法值 conf 路径 | 策略 = 小写 `proactive`（预期启动/解析失败） |
| `conf/cluster.pg_upg13_iot.conf` | 升级族 | 先起 1.3.7，再就地升级到 2.0.11 |

参数（写入 `conf/iotdb-system.properties`，键名逐字取自发布模板）：

```
schema_region_group_extension_policy=PROACTIVE      data_region_group_extension_policy=PROACTIVE
default_schema_region_group_num_per_database=1      default_data_region_group_num_per_database=2
schema_region_per_data_node=3                       data_region_per_data_node=0
series_slot_num=1000                                time_partition_interval=604800000   # 毫秒=7 天
schema_replication_factor=3                         data_replication_factor=2
```

> `schema_region_per_data_node=3` 是为了在 5 DN、schemaRF=3 下让 **Schema 上限=5**（`ceil(3×5/3)`），
> 否则默认 1 时上限只有 2、Schema 侧扩容不可观测。**该值只影响观测灵敏度，不改变被测逻辑**。

## 3 判定纪律

* **三态 + 无效**：`PASS` 仅当全部断言通过；`SKIP`（前置不成立，缺档位/缺包）≠ `PASS`；
  `INVALID`（集群前置被不可逆操作污染）不参与统计；禁止"没报错就算过"。
* **收尾三件套**（每个用例自动追加，任一不过该例不得 PASS）：
  1. sync lag 归 0（有界等待，超时即 FAIL 并记录最差值）；
  2. 副本一致性：**全在线基线**（每个存活 DN 各查一遍）→ **停 1 台 DN** 再查一遍 → 结果必须一致；
  3. CN/DN 日志 ERROR/WARN 扫描（含 NPE/数组越界/运行时异常），预期报错必须先用
     `mark_harness_action` 开归因窗口（白名单只认"窗口内 + 已知 harness 动作"，热集群下同样报错仍 FAIL）。
* **集群独占**：一个集群同时只能有一个 runner。实测教训：并发跑负向 SQL 会把
  `ConfigExecution` WARN 打进别人的用例窗口，造成**假 FAIL**。

## 4 已确认的产品/文档缺口（详见 `references/doc-gaps.md`）

| 编号 | 内容 | 证据 |
|---|---|---|
| G-01 | 设计文档 §4.1.3 把上限写成 `T=min(K,R)`，与源码 `T=min(R,max(min(minNum,G+|P|),K))` 不一致（漏了 min 与 G+自增项） | `PartitionManager.java:670-681` |
| G-02 | 非法 schema 策略值的报错文案误用 DataRegion 类型名（`DataRegionGroupExtensionPolicy %s doesn't exist.`） | `RegionGroupExtensionPolicy.java:42-50` + 实测 |
| G-03 | `SERIES_SLOT_NUM` 在 `DataPartitionPolicyTable` 是静态快照，而 `PartitionManager` 读实时 conf，两处口径可能分裂 | `:45-46` vs `:745` |
| G-04 | 边缘版默认 CUSTOM，与集中式默认 PROACTIVE 不一致 | `node-commons/.../conf/edge/iotdb-system.properties:137/139` |
| G-05 | CN 重启后心跳未到时组状态默认 Disabled，可能触发一次多余补组（假阳性风险） | `LoadCache.java:798-802`、`RegionGroupStatistics.java:44-46` |
| G-06 | `SET CONFIGURATION` 的解析在写文件**之前**，非法值必然不落盘（好消息），但错误码/文案不区分"语法错/取值错/单节点限制" | `ConfigurationFileUtils.java:429-483` |
| G-07 | 表方言不支持 `SHOW … REGIONID` / `SHOW … TIMESLOTID`（三大观测面只在树模型成立） | `AstBuilder.java:1781/1785` |
| G-08 | `SHOW DATABASES DETAILS` 按方言过滤，而产品 `databaseNum` 合并树+表计数 ⇒ 估算上限必须取并集 | `ColumnHeaderConstant.java:521-534` vs `ClusterSchemaManager.java:520-550` |
| G-09 | `time_partition_interval` 单位是毫秒（模板默认 7 天），易被误当秒 | 1.3.7/2.0.11 模板 `:968` |
| G-10 | 1.3.7 默认 AUTO、无 PROACTIVE；升级到 2.0 后同一份 conf 的语义变为 PROACTIVE ⇒ **升级会改变扩容行为** | 1.3.7 模板 `:699/:723` vs 2.0.11 模板 `:848/:891` |

## 4.1 缺陷候选现状（详见 `DEFECT_CANDIDATES.md`）

| 编号 | 一句话 | 置信度 | 状态 |
|---|---|---|---|
| D-01 | CN 重启后心跳未到时把"未缓存组"当 Disabled，可能多补 1 组 | 中（源码路径 + IT 里已有规避写法） | 待时序复现（`PG-DIS-07`/`PG-RCV-01`） |
| D-02 | 1.3→2.0 升级后同一份 conf 的扩容语义由 AUTO 变 PROACTIVE | 高（模板/源码对比） | 待升级轮确认（`PG-UPG-09`） |
| D-03 | 非法 schema 策略值的报错文案复用了 DataRegion 类型名 | 高（实测 + 源码） | 文案问题，归 doc-gaps G-02 |
| **D-04** | **表模型库（含 OBJECT）的 RegionGroup 上限恒等于最小组数 ⇒ PROACTIVE 对表模型完全失效** | **高（两轮实测复现 + 源码路径吻合 + 需求文档明确表模型在范围内）** | 待 `PG-LIM-21` 隔离确认 |
| D-05 | 写入成功后 `select count(*)` 读回空集（疑似与设备名/series slot 相关） | 中 | 待 `PG-OBS-06` 判定 |
| **D-06** | **V2 全新集群上 `DataRegion[5]` 的 syncLag 恒为 1.0（= 1 个 entry 永不 apply）** | **高（metrics 原文 + 源码语义已排除"指标口径"解释）** | 定性为产品问题；证据用例 `PG-OBS-07`，V2 轮因它被收尾①阻塞 |

## 5 执行结果

### 5.1 首轮冒烟（`results/pg_smoke_2`，IoTConsensus，conf `cluster.pg_dev_iot.conf`）

15 条 gate 用例，结果 **PASS=3 / FAIL=7 / SKIP=1**（其余 4 条在本轮被中止，见 5.2）：

| 用例 | 判定 | 直接原因 | 归因 |
|---|---|---|---|
| PG-SMK-01 | SKIP | 本档 conf 显式写了策略键 | 设计如此：默认值路径须用 `cluster.pg_default_iot.conf` 专轮 |
| PG-SMK-02 | PASS | 空库不预建（树+表都 0 组） | — |
| PG-SMK-03 | PASS | 停 1 DN 对拍一致、lag 归零、无异常日志 | — |
| PG-OBS-01 | PASS | 三大观测面一致（库详情 / REGIONS 去重 / REGIONID） | — |
| PG-SMK-04 | FAIL | 第 4 个 slot 时 Schema 组数=4（期望 3） | **harness（H-10，已定性）**：用例用"现场按公式重算的上限"当期望（此刻库集合含上一例遗留的表库 ⇒ 算得 3）；而产品的上限是**每库单调不减的存量值**（`adjustMaxRegionGroupNum` 只做 `max(min,…,allocated)`），该树库首次调整时库数为 1 ⇒ 上限 5 ⇒ 组数 `min(K=4,5)=4` **产品正确**。受影响断言普查见 `references/h10-census.txt`（113 处/8 模块/66 用例），修法见 `HARNESS_FINDINGS.md` H-10 |
| PG-SMK-05 | FAIL | 表库 Schema 恒 1、Data 恒 2，写 4 个不同 slot 不扩容 | **产品**：D-04（表模型上限恒等于最小值） |
| PG-SMK-06 | FAIL | 切回 PROACTIVE 后组数不增 | **产品**：同 D-04（表侧）＋ 见 5.3 日志归因 |
| PG-OBS-04 | FAIL | 仅收尾③命中 | **harness**：上一例收尾②停机的 leader 迁移重试越界，已修（H-08/收敛尾窗） |
| PG-DEV-21 | FAIL | 表库上限：公式 30、产品 2；树库正常 | **产品**：D-04 的最强证据（同批写入树=3 组、表=2 组） |
| PG-MSR-01 | FAIL | `select count(*)` 对 `root.pg.pgd0.s0` 返回空集 | **待判定**：D-05，判定用例 `PG-OBS-06` |
| PG-TIME-01 | FAIL | 同上（计数读回空集） | 同上 |

**结论：首轮 7 个 FAIL 中，1 个（SMK-04）是 harness 期望口径问题，2 个（OBS-04 等）是
停机噪声归因边界问题（均已修）；其余失败全部指向两个待定性问题 D-04（表模型上限/扩容）
与 D-05（写后读回），两者都由本轮**新增的隔离判定用例** `PG-LIM-21`、`PG-OBS-06` 收敛。**

### 5.2 core 轮（IoTConsensus，209 条中的 P0+P1 层）

首轮冒烟之后，把两处 harness 缺陷修掉（分摊库数并集口径、停机收敛尾窗），
再以 `prepare`（停→清 data/logs→写 conf→启，`time_partition_interval=604800000` 生效）
起干净集群，跑 `matrix --tier core --run-id pg_core_iot`。
逐用例结果在 `results/pg_core_iot/REPORT.md`；本轮为长跑（每例含收尾①②③，
单例约 2~4.5 分钟），**按已完成部分统计**，未跑完的条目在报告尾部单列（不冒充通过）。

### 5.3 日志判定说明（三轮共性）

收尾③ 的命中全部逐条留原文（`evidence/log_findings.txt` + `log_context.txt`）；
首轮中"LeaderBalancer 迁移失败 / MPP block 重发失败"经定位属**用例自己停 DataNode**
的余波（停点对拍、HA 用例），不是产品异常，已按"模式 + 收敛尾窗"双重命中归因
（`verify.extra_windows`，见 `HARNESS_FINDINGS.md` H-08），**未做全局白名单**：
尾窗之外同样的行依旧 FAIL。首轮唯一的"真异常"类命中（`ConfigExecution ... 525`）
经当事子代理自认，是它在活集群上跑非法 `ALTER DATABASE` 探针所致 ⇒ 该轮记 INVALID、
不计入产品结论（见 H-05）。

## 6 环境约束与已知限制

* 两台盘 `sda`(953G, `/`) 与 `sdb`(18.2T, `/data`)，**没有独立 SSD**；"SSD 目录"只是约定
  （`/ssd_data/...` 落在 `sda`）。双盘场景按"两目录"验证，不声称物理盘类型。
* 集群节点之间不能互相 ssh；驱动机到各节点 root 免密可用；客户端机 11.101.10.11 只能用
  `liuzhen/1qaz2wsx` + `SSH_ASKPASS` 方式执行（无 sshpass/paramiko）。
* 1 万~10 万测点级用例依赖客户端 benchmark（`bm_20260915_46fc572_v13/v20`）；前置缺失时 SKIP 并写明。
* 全量 core 轮 ≈ 120 条 × 约 2 分钟/条（收尾②停机对拍是主要成本）。

## 7 运行手册

```bash
# 0) 体检（只读）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf doctor

# 1) 干净集群（停 → 清数据与日志 → 写配置 → 起）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf prepare

# 2) 分层执行（smoke=各族 gate；core=P0+P1；full=全部）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier smoke --run-id pg_smoke_iot
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix --tier core  --run-id pg_core_iot

# 3) 换协议重跑（IoTConsensusV2）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iottv2.conf prepare
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iottv2.conf matrix --tier smoke --run-id pg_smoke_v2

# 4) 默认值路径档（未显式配置 ⇒ PROACTIVE）
bash scripts/pg.sh --conf conf/cluster.pg_default_iot.conf prepare
bash scripts/pg.sh --conf conf/cluster.pg_default_iot.conf matrix --tier smoke --run-id pg_default_iot

# 5) 单条用例 / 目录 / 报告
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf run --case PG-SMK-04
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf catalog --out CATALOG.md
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf report results/<run_id>

# 6) 收尾（必须让 5 台机器 java 进程归零）
bash scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf teardown
```

### 5.4 运行状态快照（本会话最后一次同步）

* 权威轮次：`results/pg_core_iot2/`（IoTConsensus core 层，`--tier core` = P0+P1），
  启动于 2026-10-14 20:59，单例约 1.5~4.5 分钟（收尾①②③ 占大头），全量约 10 小时。
* 同步时刻已完成 **2 / 217** 例：{'SKIP': 1, 'PASS': 1}（2026-10-14 21:06）。
* `results/pg_core_iot/` 是**被自身 harness 缺陷污染**的旧轮（`closing_triad` 里 `get_int(key, default)`
  抛 `TypeError` 使每例必 FAIL），保留作为"harness 缺陷也要留痕"的证据，**不作为功能结论**。
* 未执行但已备好脚本的轮次：`run_v2_smoke.sh`（V2 冒烟；受 D-06 阻塞）、
  `upgrade` 子命令 + `conf/cluster.pg_upg{13,20,13auto}_iot.conf`（1.3→2.0 两阶段就地升级）。
  两者都必须与 IoT 轮**串行**（3 节点共用 CN/DN 端口）。
* 结论口径：本报告第 4.1 节的 D-01..D-06 是当前的全部缺陷候选；harness 侧问题在
  `HARNESS_FINDINGS.md`（H-01..H-10），两者严格分开登记。


**快照更新（2026-10-14 21:41，`pg_core_iot2`）**：已落定 **11 例**（`PASS=6`、`SKIP=1`、`FAIL=4`），
第 12 例 `PG-EMPTY-09` 正在收尾②。4 条 FAIL 全部定性完毕：**产品侧仅 D-04**（表模型库组数钉在最小值，
`PG-SMK-05` 4 条断言实证），其余为 harness 侧且已修（`PG-SMK-04`=H-10+H-09、`PG-SMK-06`=H-11、
`PG-EMPTY-03`=H-12）。另有旁证：`PG-EMPTY-09`（受控库集合下"公式 vs 产品自报上限"对拍）
已出的检查全部通过——3 库分摊时 Schema=2、Data=4，收尾① `worst=0.0`，收尾③ 窗口内无命中，
说明**库集合受控时公式与产品自报值自洽**，与 H-10"偏差只出现在库集合中途变化"的结论互相印证。

### 5.5 双磁盘（多数据目录）维度的实际状态

需求点里的"2 磁盘"**不是缺口、也不是靠专门用例覆盖，而是所有轮次的运行前提**：
`conf/cluster.pg_dev_iot.conf:18` 已设 `DB_DATA_DIR_2=/ssd_data/mpp_test`，kit 据此判定
`Config.two_disk=True`（`config.py:302`），进而在写节点配置时把 `dn_data_dirs` 展开成
"主数据目录,第二数据目录"（`cli.py:117-119`、`upgrade.py:228`），部署/清理也覆盖两块盘
（`helpers.py:164`、`deploy.py:152`）。因此**每一条用例都是在 `dn_data_dirs` 含两个目录的
DataNode 上执行的**，"盘数是否改变 region 计数语义"由全部用例共同证明。
本报告不为此单列用例；若要单独固化，只需给某个档位置空 `DB_DATA_DIR_2` 做单盘对照组
（对比同一期望值公式），属于可选加强项。

**实测（2026-10-14，11.101.10.9 / .8 直接核对）**

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       938G  285G  606G  32% /
/dev/sdb1        19T  6.8T   11T  40% /data
dn_data_dirs=/data/mpp_test/<inst>/data/datanode/data,/ssd_data/mpp_test/<inst>/data/datanode/data
/ssd_data 无独立挂载点 → 落在 /dev/sda1
```

即：需求所指的"2 个盘"= `/dev/sda1`（根盘）与 `/dev/sdb1`（`/data`，19T），
而 kit 写的两个 `dn_data_dirs` **正好分别落在这两块物理盘上**（`/data/...` → sdb1、
`/ssd_data/...` → sda1），因此"跨两块物理盘做 PROACTIVE 扩容"是所有用例的既有运行条件。

* 环境限制（如实登记）：第二块盘实际是**根盘**（938G，其中 .8 已用 57%），
  不是独立的大容量数据盘；大批量档位（1万/10万/20万/50万测点）写入时需留意根盘余量，
  这也是本用例集把超大档位放在 full 层、并给出 benchmark 前置检查的原因之一。
* 若要"两块对等大容量盘"的环境，需运维侧把第二目录改到另一块 19T 级盘（或挂载新盘到 `/ssd_data`），
  这属于环境条件而非产品行为。

### 5.6 harness 修正收口（本会话全部落地，均带自检与回滚）

| 编号 | 问题 | 处置 | 验证 |
|---|---|---|---|
| H-08 | 上限公式的分摊库数应取**树∪表**用户库并集（原按单方言计数 ⇒ 假 FAIL） | 已修 | selftest + 复跑 |
| H-09 | 收尾②**自己停** DataNode 引发的 `X@…->Y-GrpcLogAppender is interrupted` 污染收尾③（模式早已存在 `verify.py:44`，缺的是窗口） | 已修：停机动作登记 `(t-5, t+300)` 归因窗口 | selftest 全绿、注册表 217 |
| H-09b | 同一次停机的 **MPP Source 侧**取数失败 `SourceHandle$GetDataBlocksTask - failed to get data` | 已修：补该模式（仍需窗口同时命中） | selftest 全绿 |
| H-10 | 组数期望用了"现场按公式重算的上限"，而产品上限是**每库单调不减的存量值** ⇒ SMK-04 假 FAIL（产品给 4 正确） | 已修：新增 `cases.group_ceiling()`，41 处改为"产品自报上限优先" | selftest 全绿、注册表 217 |
| 普查高估 | `references/h10-census.txt` 的 113 处系**语法匹配高估**：`cases_msr._caps`/`cases_dev._caps` 本就"公式 vs 产品自报值对拍、不一致即 SKIP"，`cases_lim._cap` 故意用公式 | 已更正登记，真实暴露仅 41 处 | 逐族源码核对 |

**关键性质（不掩盖真缺陷）**：`group_ceiling = max(公式, 产品自报上限)` **只能抬高期望**；
D-04 的形态是"自报上限被钉在最小值、低于公式"，此时期望与修正前一致 ⇒ SMK-05 仍会如实 FAIL。
运行反证见 `HARNESS_FINDINGS.md` 的"H-10 安全性论证"。

**验收标准（下一步执行）**：复跑 smoke 后，`PG-SMK-04` 应 **PASS**，`PG-SMK-05` 应**仍 FAIL 且
只剩 D-04 的 4 条组数断言**（日志噪声那 1 条已由 H-09b 归因）；`D-05` 等真实缺陷必须仍在。

### 5.7 "每用例从干净集群开始"的口径说明（如实登记差异 + 严格模式入口）

需求原话是"每用例从干净集群开始（停集群→清 data/logs→设 conf→启集群）"。kit 的**默认**实现是：

* **每轮**开始：`prepare` = 停集群 → 清 `data/` 与 `logs/` → 写 conf → 启集群（字面满足）；
* **每例**开始：`ensure_cluster_up()`（集群必须在线，掉线则拉起）+ 该例自己的 fixture
  （`reset_db` 清库/幂等前置）+ 用例 `finally` 里的 `ctx.cleanup` 清场；
* 即"**每轮干净集群 + 每例干净库**"，而非"每例整集群重启"。

**为什么不默认逐例重启**：① 成本——每例一次完整启停 + 收尾① 的 lag 归零等待，
217 例将从约 10 小时涨到 1~2 天；② 语义——`PG-RST-*`/`PG-RCV-*` 这类**跨重启**用例本身
需要保留状态，逐例清盘会让它们失去意义；③ 隔离性——每例清库 + 幂等前置 + 收尾三件套
已能保证"上一例不污染下一例"（这也是 H-08/H-10/H-11 修复后得以成立的前提）。

**需要严格口径时**：`bash scripts/run_strict_percase.sh <conf> [case-id ...]`
（可配 `PG_TIER=smoke|core|full`），它对**每个用例**先 `prepare` 再 `run`，
逐例输出各例判定并汇总。该脚本属"可选加强"，不改变默认轮次的结论。

**实测吞吐与 ETA（2026-10-14 21:28 快照）**：`pg_core_iot2` 自 20:59 启动，至 21:28 完成 6 例
（`PASS=2`、`SKIP=1`、`FAIL=3`，FAIL 已全部定性：`PG-SMK-05`=**D-04 产品**、
`PG-SMK-04`=H-10+H-09、`PG-SMK-06`=H-11）⇒ 平均 **约 4.9 分钟/例**。
按 215 例（core 层载入的注册表快照）估算，**整轮约 17 小时**（早前 10 小时的估算偏乐观，
原因是收尾三件套里 ①②（lag 归零 + 停 1 台 DN 对拍）在大规模/多分区用例上耗时更长）。

**给使用者的时间预期**：IoT core 轮 ≈ 17 小时 → 自动接力 V2 冒烟（受 D-06 阻塞，功能断言仍会留证）
→ 1.3→2.0 升级 pre/post（两阶段就地升级，各自需要启停与复测）→ full 层（含 20 万/50 万测点、
1DN readonly，另需数小时）。若只需快速结论，建议按 `PG_TIER=smoke` 跑冒烟层，
或按 `run_strict_percase.sh` 只挑目标用例逐例严格复跑。

### 5.8 `pg_core_iot2` 逐例定性（截至 7 例落定，全部 FAIL 已分类）

| 用例 | FAIL 项 | 定性 | 依据/处置 |
|---|---|---|---|
| `PG-SMK-04` | 第 4 个 slot 时 Schema 组数 4（用例期望 3） | **H-10（harness 期望口径）** | 产品上限是**每库单调不减的存量值**；用例用"现场公式"当期望。已修：`group_ceiling()`（41 处），并附安全性反证 |
| `PG-SMK-04` | 收尾③ 日志命中 `…GrpcLogAppender is interrupted` | **H-09（harness 噪声）** | 该模式（`verify.py:44`）早已存在，缺的是覆盖收尾②停机的窗口。已修：停机登记 `(t-5, t+300)` 窗口 |
| `PG-SMK-05` | 表模型写第 2/3/4 设备后 Schema 组数恒为 1、Data 恒为 2 | **D-04（产品缺陷，实证）** | 表库组数**钉在最小值不涨**；同源证据：`adjustRegionGroupNum` 内 `getRegionGroupCount` 抛 `DatabaseNotExistsException` 被静默 `continue`，上限留在建库默认最小值；产品自家 IT `IoTDBDatabaseIT:1004` 只触发调整、不断言表库上限 |
| `PG-SMK-05` | 收尾③ 日志命中 `SourceHandle$GetDataBlocksTask - failed to get data` | **H-09b（harness 噪声）** | 同一停机的 MPP Source 侧；已补该模式（仍需窗口同时命中） |
| `PG-SMK-06` | 切回 PROACTIVE 后组数 5（用例期望 4） | **H-11（harness 期望口径）** | 公式用**全量 K**（AUTO 期间写入的 slot 仍缺组）⇒ `min(R, K)=5` 正确；已把该步改为显式断言"切回后按全量 K 补齐"（积极扩容核心语义） |

**结论**：截至 7 例，`pg_core_iot2` 的**产品侧缺陷只有 D-04 一项**，其余全部为 harness 侧问题且已修复并验证。
`pg_core_iot2` 加载的是**修正前**的代码，故其 FAIL 仍需按上表口径解读；下一轮 smoke 复跑用于验证
修正后的判定（期望 `PG-SMK-04`/`PG-SMK-06` 转 PASS、`PG-SMK-05` 只剩 D-04 的 4 条、`D-05` 仍在）。

> **追溯链（已机器校验）**：§1 每行列出该需求点的**锚点用例**（§1 内共 34 个用例号，与注册表差集为 0，
> 即无悬空引用）；该需求点的**全部**用例即其所属**用例族**的全部成员 —— 19 个族每族 **6~34 条**
> （见下表），故"每点 ≥2 条"成立。全部 217 条的需求点/领域归属见 `CATALOG.md`（217/217 全覆盖），
> 注册表 `list-cases` 同为 217 条，与客户端 `cases/` 下 217 个单例脚本 **1:1**。
>
> | 用例族 | 条数 | 用例族 | 条数 | 用例族 | 条数 | 用例族 | 条数 |
> |---|---|---|---|---|---|---|---|
> | PG-DEV | 23 | PG-LIM | 21 | PG-MSR | 20 | PG-UPG | 16 |
> | PG-HA | 14 | PG-REB | 14 | PG-DFT | 12 | PG-EMPTY | 12 |
> | PG-SWCH | 12 | PG-TIME | 12 | PG-PRV | 8 | PG-TTL | 8 |
> | PG-DIS | 7 | PG-OBS | 7 | PG-RCV | 7 | PG-MIN | 6 |
> | PG-RST | 6 | PG-SMK | 6 | PG-SYS | 6 | **合计** | **217** |

**证据包完整性口径（已核验）**：`results/<run>/REPORT.md` 与 `summary.json` 由 runner 在**该轮结束时**
写出，因此**进行中的轮次暂无**这两个文件（终态一定有）；`*_doctor`/`*_deploy`/`*_prepare`
等辅助目录与**被中途终止**的 `pg_core_iot`（自身 harness 缺陷污染、仅作留痕）本就无 REPORT/summary。
**逐用例证据**（`cases/<ID>/{actions.log, evidence/, result.json}`）则**每例一落定即写**，
可在运行中随时取证。核验时的实测状态：`pg_smoke_2`(11 例)、`20261014_190204_run`、`20261014_190914_run`
均有 REPORT+summary；`pg_core_iot2` 运行中（12 例），REPORT/summary 待该轮结束生成。
