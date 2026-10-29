# 已确认的产品缺陷（跑本 skill 前先看）

本文件记录**已提 PLM 且研发确认**的产品缺陷，避免重复定性；跑用例命中相同现象时，
先按这里的"识别特征"对号入座，再决定是否新开问题。

## TDB-1169（PLM 1169）：移除 DataNode 时 region 迁移窗口内的写入永久丢失 ⇒ 副本数据不一致

- **PLM 工作项**：https://plm.infra.timecho.com/iterations?productId=1&itemId=1169
- **RN 验证文档**：https://plm.infra.timecho.com/docs/917
  （标题 `TDB-1169 【V2.0.12.1】【Region迁移】移除DataNode时待移除节点快照后仍有写入，未同步到目标节点即被移除致副本数据丢失`，
  内容含完整时间线、日志行号、证据清单）
- **发现版本**：V2.0.12.1（迭代 V2.0.12.1）｜负责人 王頔｜所属组长 陈荣钊｜验证人员 刘珍｜优先级 P1
- **状态**：研发已确认是 bug，方案待出（改进方向：待移除节点的 region 在触发发送快照时应进入只读；
  后续版本给 DN 增加获取 region 粒度状态的接口）

### 现象（一句话）
移除 DataNode 时，region 迁移过程中**待移除节点在快照发送完成之后仍产生写入**；这些写入还没同步到
新的目标副本，该节点就被彻底移除 ⇒ **这部分写入永久丢失，副本数据不一致**。

### 研发确认的根因（原话）
> `.10 在发送完快照以后因为 .9 被 stop readonly，在 .10 上面重试，所以又有了新的写入。
>  这部分写入在同步到 .9 之前 .10 就被彻底移除了。`

### 时间线（2026-10-01 现场，region 11）
| 时间 | 事件 |
|---|---|
| 06:51:10 | 集群启动 |
| 06:52:16.477 | leader 由 `.10` 转到 `.8` |
| 06:52:16.528 | region 迁移开始 |
| 06:52:17,051 | `.8` 产生快照（`SnapshotTaker`） |
| 06:52:17,079 | `.9` 装载快照（`SnapshotLoader`，3 文件 61.27 KB） |
| 06:52:17,854 | leader 转到 `.9` |
| 06:52:19,795 | `.9` 进入 ReadOnly（`DataNode-Shutdown-Hook`） |
| 06:52:37.059 | 迁移结束 |

成员变更：`{.10(id1), .8(id6)} → {.9(id2), .8(id6)}`。`.10 ↔ .9` 的同步通道曾建立
（`initialSyncIndex 403`，entries `404–408`），但 `.9` ReadOnly 后**拒收**同步：
`code:600 fail to sync logEntries because system is read-only`。`.10` 上共有 **4 轮**重试窗口
（`DN.10:20593-20614`、`20621-20625`、`20626-20630`、`20635-20639`）均被拒；注意当轮 WARN 文案
写的是 `for 1 times`，与实际的 4 轮不符（已作为疑点记在 PLM 1169「待确认」）。

### 跑本 skill 时的识别特征与取证建议
- **识别特征**：`REMOVE DATANODE` 结束后出现副本不一致/丢数据，且时间点上伴随
  ① 目标节点进入 ReadOnly、② 源节点（待移除节点）上出现 `fail to sync logEntries … read-only`、
  ③ 源节点随后被彻底移除。
- **复现/取证要抓的证据**（缺一条就难定性）：
  1. 待移除节点 DN 日志中的 `SettleCompaction`/同步模块 WARN 与 `code:600` 拒收记录（含行号）；
  2. `SnapshotTaker` / `SnapshotLoader` 时间戳与快照文件数、字节数；
  3. 成员变更与 leader 变更时间点（CN 侧 `DN.10`/`CN.9` 相关日志）；
  4. 被移除节点在"快照完成 → 被移除"之间是否仍有写入（本轮由研发加 log 版本确认）。
- **原始证据（本机留存）**：
  - `/home/ubuntu/remove_cn_dn/work/0928_add_log/analysis/MIGRATION_TIMELINE_REGION11_20261001.md`（完整时间线）
  - `/home/ubuntu/remove_cn_dn/work/0928_add_log/analysis/ROW_PROOF_20261001_wal_fake_node.md`（行级证明）
  - `/home/ubuntu/remove_cn_dn/deliverables/rd_evidence_20261001_fake_node_wal.tar.gz`（95 个文件）
  - 现象描述正文：`/home/ubuntu/remove_cn_dn/rn_verify/remove-node/PLM_REGION_REPLICA_LOSS_V2.0.12.1.md`
## RC5 写路径 NPE（`get length` on null Binary）—— **已在 `720a3f3` 修复并复验**

- 旧包（RC5 `aaf460d`）：写 OBJECT 列（table/table_view 的 `s_10`/`s_11`）触发
  `WriteProcessException: java.lang.NullPointerException`，日志门禁因此把**每一条** remove 用例判红。
- 新包 `720a3f3`（`fix length calculation of null Binary`，2026-10-10）：同一矩阵 **NPE 签名 0**，
  判定恢复到 PASS 27 / FAIL 1。
- **教训**：不要用白名单屏蔽该 NPE——`305: null`、迁移卡死、移除后节点起不来等失败都是它的**派生现象**，
  屏蔽后会一起被掩盖。


## 移除 DataNode 时 `RemoveRegionPeerProcedure` 卡死 / `SHOW MIGRATIONS` 不收敛 —— **已知问题（lost quorum，V2-1215 同类）**

### 识别特征（跑本 skill 时命中该签名即按"已知"标注）
```
remove is not progressing: RemoveRegionPeerProcedure has been stuck for <N>s on <host>
SHOW MIGRATIONS did not become empty after the remove
remove procedure is wedged and will not finish: RemoveRegionPeerProcedure has been stuck for <N>s on <host>
```
ConfigNode 侧伴随：`WARN ProcedureExecutor$WorkerMonitor:993 - Worker stuck`
`ProcedureCoreWorker-N(pid=..)(RemoveRegionPeerProcedure), run time <ms>`
`show migrations` 会显示一条 `MIGRATE … CurrentState=CHECK_REMOVE_REGION_PEER … ProcedureStatus=WAITING`。

### 已知原因（`troubleshooting.md` 原文）
**区域成员变更丢失法定人数（lost quorum）**：被迁移 Region 的副本里，除"被移除节点"外，
另一个存活副本持有者处于**不可投票状态**（ReadOnly / Unknown 停止 / Adding+ReadOnly），
幸存持有者**凑不够多数派**，成员变更永远无法提交 ⇒ 移除流程卡死、被移除节点长期停留 `Removing`。
**间歇性**：需要"不可用节点恰好是该 Region 的幸存副本持有者"才会命中，集群重置后重跑可能通过。

### 现场取证（2026-10-12，RC6 `7ae8713e`，用例 `dn_remove_other_unknown`）
- 运行目录：`results/20261012_wedge2_r1`（FAIL，962.6s）；现场文件 `wedge_{regions,datanodes,confignodes,migrations}_*.raw`
- 节点：`.9`=**Unknown**（用例停掉的另一副本）、`.10`=**Removing**（被移除）、`.8/.6/.7`=Running
- Region 4：副本 {`.9` Unknown, `.10` Removing, `.7` Running} ⇒ **可投票成员仅 1，无多数派**
- 卡点：`ProcedureId 13 MIGRATE RegionId 4 FromNodeId 6(.10) → ToNodeId 7(.7)`,
  `CHECK_REMOVE_REGION_PEER`, `WAITING`, 持续 **6 分 2 秒**

### 关联与处置
- 关联已知问题：**V2-1215**（tc117：Adding peer 变 ReadOnly ⇒ REMOVE DATANODE 卡死，同根因）、
  **TDB-396**（"剩余副本足以完成成员变更时应成功"——设计约定待研发确认）。
- 处置：命中时**如实报 FAIL 并保留全部证据**，同时在报告中**标注为已知问题**；
  如需让用例通过：清除不可投票状态（ReadOnly ⇒ `set system to running on local;`）后重跑，
  或用 `PROCEDURE_STALL_SEC=0` 等待其自行收敛（**不改变产品行为，仅影响判定**）。
- **未定性部分**（不属已知）：`dn_remove_other_diskfull` 的"被移除节点拒绝启动"、`cn_leader_remove_kill9_follower`
  的控制面中止——出现时仍需单独确认。

## TDB-835（PLM 835）：Region 迁移后 OBJECT 文件带版本号，表大小缓存未适配 ⇒ 冷启动后 object size 恢复不出来

- **PLM 工作项**：`TDB-835`（`bash "$PLM_ROOT/scripts/plm-cli.sh" --json rn get --number TDB-835`）
- **发现版本**：V2.0.12.1（RC8/RC9 期间）｜**修复版本**：RC9（提交 `78c79493`
  *Fix OBJECT size recovery for versioned bin files*）
- **原缺陷环境**：1 ConfigNode + 3 DataNode（`.1` CN；`.2/.3/.4` DN），**每节点 3 块盘**
- **状态**：已修复；本 skill 保留为**回归护栏**

### 现象（一句话）
Region 迁移之后 object 文件名多了版本后缀（`<time>_<version>.bin`），
`ObjectTableSizeIndexWriter.buildIndexFromScratch` 仍只认 `<time>.bin`，
解析抛异常后跳过该文件 ⇒ 在**没有表大小缓存**的一次启动里（`TableObjectSizeFile_*` 不存在的冷启动），
这些 region 的 object size 恢复成 0 / 缺失，而磁盘上对象文件明明存在。

### 修复内容
新增 `ObjectPathNaming.tryParseTimestampFromBinFileName`，同时接受
`<time>.bin` 与 `<time>_<version>.bin`（提交 `78c79493`）。

### 本 skill 如何验证（用例 `dn_object_size_after_migration`，extras=`object_size,cold_restart`）
1. `REMOVE DATANODE` 触发 region 迁移，等迁移收敛；
2. 用 `SHOW REGIONS FROM <table_db>`（**必须是 relational 方言**；tree 方言的 `SHOW REGIONS`
   看不到表模型库，只看得到 `root.__audit`/`root.__system`）逐副本取 `ObjectSize`；
3. 与磁盘上 `<data dir>/object/<regionId>/**/*.bin` 的真实字节数比对：
   **不得为负、不得在磁盘有对象时报告 0、允许 10% 或 1 MiB 误差、副本之间必须一致**；
4. `cold_restart`：停集群 → 删除所有 `TableObjectSizeFile_*`（制造"无缓存启动"）→ 起集群 → 再审计一遍。

### 判定口径
- RC11（`ea4f835`）实测：迁移后与冷启动后各 **10 个副本、10 个有实体 OBJECT 文件、0 个问题**（PASS）。
- 若命中：`ObjectSize` 为 0/负值而磁盘有 `.bin` ⇒ **TDB-835 回归**，按回归报 FAIL 并保留
  `object_size_audit.json` / `object_size_audit_cold.json`。

## TDB-861（PLM 861）：Region 迁移后新副本保留了已被 DELETE 的 OBJECT 文件

- **PLM 工作项**：`TDB-861`｜**发现版本**：V2.0.12.1（RC9 提交）｜**计划修复**：V2.0.13.1
- **原缺陷环境**：1 ConfigNode + 4 DataNode（`.1` CN；`.2~.5` DN），**每节点 3 块盘**
- **RC11（`ea4f835`）状态**：**未修复** —— 修复提交 `c459464b1f0`
  *Exclude unreferenced objects from region snapshots* 不在 RC11 HEAD 的祖先链上

### 现象（一句话）
`SnapshotTaker` 以**硬链接**方式收集 region 目录下的对象文件，与异步 OBJECT GC 并发时，
GC 已把某些文件 unlink（逻辑删除完成、物理文件已移除），快照仍然把它们的硬链接带进新副本
⇒ 迁移完成后新副本的 `object/` 目录里留着 leader 侧**已经删除**的文件。

### 本 skill 如何验证（用例 `dn_object_delete_residue`，extras=`object_delete_residue`）

> 2026-10-28 重做注入：原方案（DELETE burst + REMOVE 的迁移时机）在 master 上**永远拿不到证据**，
> 现改为「OBJECT 覆盖 churn + 定向 `MIGRATE REGION`」，窗口按需成立。

1. 自建探针表 `objprobe.t (time, dev, o object)`，写入 100 行唯一 OBJECT（`to_object(true, 0, X'..')`）；
2. **覆盖写入**同样的 (dev, time) 行，每轮换一批新 payload → 上一轮 payload 变成垃圾，OBJECT GC
   持续 unlink 并写 `log_datanode_object_deletion.log`；
3. churn 跑起来（GC 记录开始增长）后，对探针表所在 region 执行
   `MIGRATE REGION <id> FROM <leaderId> TO <空闲DataNode>` —— 迁移要取快照，正是缺陷需要的并发窗口；
4. 迁移完成后逐副本比较：follower 有、leader 没有的文件 ∩ leader 的删除日志 = 确认残留。

**实测数字（master `939750de80`，3C5D，2026-10-28）**

| 注入手段 | GC 删除记录 | 结论 |
|---|---|---|
| DELETE 整表（旧方案，两次尝试） | 4 条 / 6 条（门槛 20） | SKIP：窗口没建立 |
| DELETE 整表（探针复测，master） | **0 条**（文件被 TSFile 逐出时回收，不写 GC 日志） | 旧方案在 master 上不可能成立 |
| 覆盖 churn，100 行/轮 | **每轮 ~40 条/节点**，40 秒内累计 178-180 条 | 窗口成立 |
| churn + `MIGRATE REGION` | 迁移 20-25 s 内 GC 仍在删（窗口期新增 80 条） | 审计可用：10 副本、0 组差异、0 确认残留 |

**用例实跑（2026-10-28，master `939750de80`，3C5D，IoTConsensus）**

```
21:16:46  迁移计划：region 11（2 个副本，leader 节点 7 11.101.10.9）→ 目标节点 1 11.101.10.7
21:17:06  OBJECT churn 已启动：1 轮，GC 新增记录 20 条（窗口门槛 20）
21:17:08  MIGRATE REGION: Msg: The statement is executed successfully.
21:17:33  迁移完成，churn 已跑 1 轮
21:17:52  OBJECT 删除残留审计：10 个副本，leader 侧 GC 记录 200 条，0 组差异，0 个确认残留
21:20:48  === dn_object_delete_residue: PASS (697.0s)
```

从 `SKIP（4/6 条 GC 记录，门槛 20）` 变成 `PASS（200 条，窗口期新增 80 条，0 残留）`。

**用例不再整节点移除**：`selector=skip` 只做 warmup 后直接进入审计。原因：`REMOVE DATANODE`
在 3C5D 上曾被 LeaderBalancer 同时把 region 4 的 leader 挪到待删节点，导致
`Some regions are migrated failed ... migratedFailedRegions: [DataRegion 4]` 回滚，
用例卡在等节点消失。快照窗口由定向 `MIGRATE REGION` 注入，覆盖同一段产品逻辑，且不受均衡抖动影响。

**固定下来的实现**：`rcdn.object_audit.run_object_snapshot_probe()`（用例里自动调用）、
`scripts/object_probe.py`（单独跑，便于复现/对照）、配置项
`OBJECT_PROBE_MIGRATE` / `OBJECT_PROBE_DB` / `OBJECT_CHURN_ROWS` / `OBJECT_CHURN_INTERVAL_SEC`。
`OBJECT_PROBE_MIGRATE=false` 时退回旧的 DELETE burst 方案（只对 DELETE 仍写 GC 日志的构建有意义）。

**踩过的两个坑**

1. `MIGRATE REGION` 必须用**库所属模型**的方言执行：表模型的库用 tree 方言报
   `900: The region's database <db> is belong to TABLE model, but the model you are operating is TREE`；
2. OBJECT 列不能用 `X'..'` 直接插（`507 data type is not consistent`），也不能 `cast(.. as object)`
   （`701 Unsupported expression`），唯一可用写法是 `to_object(true, 0, X'..')`。

### master 上的状态（2026-10-28）

`939750de80` 的祖先链里有 `c459464b1f`（后以 `6897804350` 再入）*Exclude unreferenced objects from
region snapshots*，即 TDB-861 已修复。用上面的固定注入在 master 上跑：窗口成立、残留 0 组 →
用例应判 **PASS**（属于"修复后不再复现"的结论，不是"没跑到"的 SKIP）。

负向对照（证明探针能抓到残留）需要未修复构建：本机 `.6` 上有
`/data/mpp_test/v20121rc11_1023_ea4f835_unpack` 与 `/data/mpp_test/timechodb-2.0.12.1-bin.zip`，
在 RC11 上跑同一条探针应报 FAIL（确认残留 > 0）。

### RC11 负向对照（2026-10-28/29，RC11 `ea4f835`，2.0.12.1）

目的：证明探针在**未修复**构建上会报残留。构建确认：`git merge-base --is-ancestor c459464b1f ea4f835`
为假（RC11 提交 2026-10-23，修复提交同日但不在该分支），即 RC11 不含修复。

| 尝试 | 注入 | 结果 |
|---|---|---|
| A | 覆盖 churn（100 行/轮）+ `MIGRATE REGION` | GC 记录 300 条、churn 2 轮、迁移 14 s → 0 残留 |
| B | 整表 DELETE 后立即 `MIGRATE REGION`（400 行） | 迁移 19.6 s，leader 新旧副本文件均 0 → 0 残留 |
| C | 先用 benchmark 写 4.10 GiB OBJECT，整表 DELETE 后逐 region 迁移（5 个 region） | 每个 region 迁移 24-34 s，leader 文件 0、删除日志 0 → 0 残留 |
| D | 覆盖 churn 期间逐秒观测文件/日志 | 覆盖后 leader 仍有 10 个文件、删除日志 10 条；GC 与删除日志基本同步 |

机制结论（源码确认）：RC11 的 `SnapshotTaker.snapshotObjectFiles()` 复制整个 object 目录，
所以残留前提是"**快照时刻磁盘上存在未引用文件**"。黑盒注入下这个前提很难成立：

- DELETE 走 TSFile 逐出路径，对象文件与行一起被回收，删除日志为 0，没有可复制的陈旧文件；
- 覆盖写入确实产生未引用文件，但 OBJECT GC 在日志落盘后 ~1 s 内就 unlink，快照窗口极窄；
- 上游修复自带的单测是构造 **GC 失败/挂起**（`delete-last-before-gc-failure`、`pending-gc`）才留下
  陈旧文件，黑盒集群无法直接制造这种状态。

因此 RC11 上探针结论是 **PASS（未复现）**，而不是 FAIL；这与"修复不存在"并不矛盾——本场景没有
把 GC 拖到失败/挂起，快照自然拿不到陈旧文件。要做出真正的 FAIL，下一步可选：
(a) 在 RC11 上注入 GC 失败（如把 object 目录设为只读/删除失败）；
(b) 结合 kill -9 让 GC journal 尾部撕裂（`ObjectGcJournalReader` 的 checkpoint 不回退）；
(c) 直接在单测环境复跑上游 `ObjectOverwriteCleanupTest` 场景。

### 尝试 E：海量 OBJECT 文件（~1.1e5）——文件数不是关键变量

用 `BM_OBJECT_LENGTH=1024 / DEVICE_NUMBER=1000 / LOOP=100 / DATA_CLIENT=10` 写入 **108 864** 个
OBJECT 文件（`POINT_STEP=0` 让每轮覆盖同一个点），然后逐个 region 迁移（每个 region ~21 700 个
文件，迁移耗时 ~5 min，因为 RC11 的 `SnapshotTaker` 把整个 object 目录复制一遍）。

结果：迁移完成后 leader 与新副本各 21 700 个文件、**删除日志都是 0 条**，多余文件 0、残留 0。
说明这批文件全部仍被 TSFile 引用（覆盖版本还没随 TSFile 逐出），没有任何"待 GC"的陈旧文件，
文件再多也没有可泄漏的对象。触发残留的必要条件不是文件数量，而是**快照时刻存在已判定为垃圾、
但尚未 unlink 的文件**——上游单测靠 GC 失败/挂起制造这个状态。

### 尝试 F：GC 故障注入（2026-10-29）——仍然 0 残留，但暴露两个新事实

| 注入 | 手法 | 结果 |
|---|---|---|
| F1 | 对 region 的 20 个 `.bin` 做 `chattr +i`，再覆盖写 | 迁移**直接失败**：`ConsensusGroupModifyPeerException: unknown error when taking snapshot`（`SnapshotTaker$1.visitFile` 复制不可变文件失败），迁移回滚，region 仍是原 2 副本 |
| F2 | `chattr +a`（append-only）锁定 region 目录，覆盖写后再迁移 | 迁移 20 s 成功；快照里只有 20 个 live 文件（见下），0 残留，内容一致 |
| F3 | `chattr +a` 后整表 `DELETE`（unlink 被挡住：leader 仍有 20 个文件、日志 0）→ 迁移 | 迁移 19 s 成功；新副本 0 文件、0 残留——**删除记录随 WAL/journal 复制到新副本并被执行**，所以没有泄漏 |

两个新事实：

1. **object 文件名是哈希地址**（`object/<region>/<2 字符>/<base32>`），同一 (device,time) 覆盖写会命中同一路径，
   所以"同点覆盖"不产生陈旧文件——这也解释了 F2 里文件数始终是 20。
2. **对象 unlink 被阻塞时，region 迁移会整体失败**（F1），报 `unknown error when taking snapshot`；
   也就是说 GC 故障不是"悄悄留下垃圾"，而是把迁移一起拖垮——这一点值得单独记录。

结论：残留需要"快照复制了陈旧文件"**且**"新副本没有收到对应删除记录"。F3 说明删除记录会正常复制过去，
所以只有**journal 尾部撕裂/检查点不回退**（上游 `ObjectGcJournalReader` 修的那个点）才会丢记录，
需要 kill -9 在 journal 写入中途（选项 b）。

### 单点 4 GiB OBJECT：可以分批写（2026-10-29 实测）

`to_object(isEOF, offset, X'<chunk>')` 带偏移量和 EOF 标记，一个 OBJECT 值可以由多段拼出来：
4 GiB 单点 = 同一 `(device, time)` 上按偏移递增的多次 INSERT。实测（RC11 `ea4f835`，8 MiB/段，512 段）：

- 写入 4096 MiB 用 **252 s**（16 MiB/s），落盘 `.bin` 恰好 4 294 967 296 字节；
- 两个副本 `.bin` 的 sha256 都是 `4bfa1b1094583395a8fe5bbd8417bf9c24186440dcd3f4297d7207dfd289372b`，与客户端写入的
  图案一致；
- `MIGRATE REGION` 迁移该 region 用 **103 s**，新副本 `.bin` 大小与 sha256 完全一致；
- 用例 `dn_object_single_4g` 全流程 PASS（1421 s，含集群重置与一致性巡检）。

读也支持分段：`read_object(o, offset)`、`read_object(o, offset, length)`（RC11 已实现，长度按剩余字节截断）。
只有**整文件读** `read_object(o)` 会报 `701: Read object size 4294967296 is too large (size > 2G)`；
分块读不受此限。所以 4 GiB 单点的校验改为：`length(o)` 定长 + 每 256 MiB 一段 `length(read_object(o, off, len))`
与 `sha256(read_object(o, off, len))` 逐段比对（16 段），迁移前后各做一遍。

实测（2026-10-29，RC11 `ea4f835`）：写入 4096 MiB 用 279.5 s（14.7 MiB/s，8 MiB/段 × 512 段）；
迁移前 16/16 段一致；`MIGRATE REGION`（region 29 → `11.101.10.8`）103 s；迁移后 16/16 段一致；
两个副本 `.bin` 均 4 294 967 296 字节。用例 `dn_object_single_4g` PASS。
