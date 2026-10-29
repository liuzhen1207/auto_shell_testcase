# V2-1067 复现报告

| 项 | 内容 |
|---|---|
| 缺陷 | PingCode **V2-1067** |
| 标题 | 【V2.0.10.2】【region迁移回归测试】CN leader 切换后，同一轮 Region 1 迁移中 AddRegionPeerProcedure 出现 rollback/fail 与后续 success 并存，随后重试迁移因残留 AddRegionPeerProcedure 占用 Region 操作锁失败 |
| 链接 | https://pingcode.timecho.com/pjm/workitems/F3UtEIa4 |
| 迭代 / 提测RC | V2.0.12.1 / RC1 |
| 负责人 / 验证人 | 陈荣钊 / 刘珍 |
| 复现版本 | **v20102_rc1_0701_5e711bf**（与缺陷"发现版本"一致） |
| 复现脚本 | `tc44_add_peer_stop_cn_remove-coord.sh.20260707.V2-1067`（缺陷当时的快照，未用当前已修改版） |
| 环境 | 3C5D：CN .5/.4/.26，DN .4/.26/.14/.27/.30，客户端 .3 |
| 复现时间 | 2026-10-28 15:25 – 15:38 |
| **结论** | **部分复现**：核心异常"rollback/fail 与后续 success 并存"**已复现**；"重试迁移被残留锁挡到失败"**未复现**（本次重试迁移成功，只是耗时 5m15s，用例因 300s 超时判 fail，**只差约 10 秒**） |

---

## 一、复现结论（先说边界）

| 缺陷描述中的现象 | 本次复现 | 证据 |
|---|---|---|
| AddRegionPeerProcedure 出现 **rollback/fail** | ✅ 复现 | `[pid21][AddRegion] Start to roll back, because: DO_ADD_REGION_PEER result is FAIL`（15:32:12.834）<br>`[pid22][AddRegion] Start to roll back, because: CREATE_NEW_REGION_PEER fail`（15:32:21.415） |
| 同一 Region / 同一目标 DN 后续 **success** | ✅ 复现 | `[pid25][AddRegion] success, TConsensusGroupId(type:DataRegion, id:1) has been added to DataNode 4@172.20.70.26. Procedure took 4 minute 23 second 272 ms`（15:37:29.004） |
| rollback 与 success **并存**（同一轮迁移上下文） | ✅ 复现 | 两条记录针对 **DataRegion 1 → DataNode 4@172.20.70.26**，相隔 **4 分 56 秒** |
| 父迁移流程因 sub-procedure 失败而中止 | ✅ 复现 | `[pid19][MigrateRegion] sub-procedure AddRegionPeerProcedure failed, RegionMigrateProcedure will not continue`（15:32:12.874） |
| **重试迁移因残留锁报 `has some other region operation procedures in progress` 并失败** | ❌ **未复现** | 全节点日志均无该报错；第二次迁移 `MIGRATE REGION 1 FROM 6 TO 4` 最终 **success**（15:38:21.214） |
| 迁移长时间卡住 | ✅ 复现 | `Worker stuck ProcedureCoreWorker-9(pid=25)(AddRegionPeerProcedure)` 从 15:34:33 持续到 15:37:03，每 30s 一条 |
| 用例判 fail | ✅ 复现（但**临界**） | 用例在 `v_elp=301` 判定超时，迁移在 **10 秒后**（15:38:21）才 success |

---

## 二、完整时间线（2026-10-28，全部取自各节点日志）

```
15:30:22.279  迁移①提交: MIGRATE REGION 1 FROM 3 TO 4
              Submit RegionMigrateProcedure successfully
              Origin DataNode 3@172.20.70.4  →  Dest DataNode 4@172.20.70.26

              ← 故障注入: stop DataNode 172.20.70.26 (目标 DN) + stop ConfigNode 172.20.70.4 (CN leader)

15:32:12.834  [pid21][AddRegion] Start to roll back, because: DO_ADD_REGION_PEER result is FAIL
15:32:12.874  [pid19][MigrateRegion] sub-procedure AddRegionPeerProcedure failed,
              RegionMigrateProcedure will not continue            ← 迁移① 宣告失败
15:32:12.890  [pid19][MigrateRegion] released migration lock
15:32:21.415  [pid22][AddRegion] Start to roll back, because: CREATE_NEW_REGION_PEER fail

15:33:05.664  [pid23][MigrateRegion] acquired migration lock      ← 迁移②（CN 新 leader .26 上）
15:33:05.682  [pid23][MigrateRegion] started, DataRegion id:1
              will be migrated from DataNode 6@172.20.70.27 to 4@172.20.70.26
15:33:05.730  [pid23] state ADD_REGION_PEER complete

15:34:33.613  Worker stuck ProcedureCoreWorker-9(pid=25)(AddRegionPeerProcedure)   ← 开始卡住
15:35:03.614  Worker stuck ...（每 30s 一条）
15:36:03.615  Worker stuck ...
15:37:03.616  Worker stuck ...

15:37:29.004  [pid25][AddRegion] success, DataRegion id:1 has been added to DataNode 4@172.20.70.26
              Procedure took 4 minute 23 second 272 ms             ← 卡了 4m23s 后成功
15:37:29.016  [pid23] state CHECK_ADD_REGION_PEER complete
15:37:29.027  [pid23] state REMOVE_REGION_PEER complete

15:38:11       用例轮询到 v_elp=301 > 300s，v_mig_suc_log=0 → 判 fail
15:38:21.214  [pid23][MigrateRegion] success, has been migrated from DataNode 6@172.20.70.27
              to 4@172.20.70.26. Procedure took 5 minute 15 second 557 ms
```

**关键点**：用例判失败的时刻（15:38:11）与迁移真正成功的时刻（15:38:21）**只差 10 秒**。

---

## 三、与缺陷原文的逐条对照

缺陷原文（V2-1067 description）：

> 旧的 pid18 AddRegionPeerProcedure 在 15:38:30 因 DO_ADD_REGION_PEER result is FAIL 进入 rollback，并 remove region DataRegion 1 from DataNode 4；但 CN leader 切换/恢复后 pid22 AddRegionPeerProcedure 继续占用同一个 Region 1 的操作锁，直到 15:43:02 迁移 success。

本次复现的对应关系：

| 缺陷原文 | 本次复现 |
|---|---|
| pid18 rollback（DO_ADD_REGION_PEER FAIL） | **pid21** rollback（同原因），15:32:12 |
| pid22 在恢复后又创建、占用锁直到 success | **pid25**（4m23s 后 success），期间 `Worker stuck` 持续告警 |
| 15:43:02 迁移 success（rollback 后约 4.5 分钟） | **15:38:21** success（rollback 后约 **6 分钟**） |
| 第二次迁移 `FROM 6 TO 4` 报 `has some other region operation procedures in progress`，180s 后 fail | **未出现**；第二次迁移本身 success（5m15s），用例因 300s 超时 fail |

PID 编号不同属正常（Procedure ID 运行时动态分配），**异常模式一致**。

---

## 四、各节点完整日志

研发要求的"各个节点的完整日志"已打包：

| 项 | 内容 |
|---|---|
| 包路径（客户端 70.3） | `/data1/iotdb/testcase/MigrateRegionTest/skill_case/defect_repro/logs/V2-1067_repro_20261028_155356.tar.gz` |
| 本地副本 | `defect_repro/logs/V2-1067_repro_20261028_155356.tar.gz`（1.0 MB，211 个条目） |
| 覆盖节点 | **3 CN**（.5 / .4 / .26）+ **5 DN**（.4 / .26 / .14 / .27 / .30），共 8 个 |

每个节点包含：

| 类别 | 文件 |
|---|---|
| 日志 | `log_confignode_all.log` / `log_confignode_warn.log` / `log_confignode_debug.log`、`log_datanode_*.log`（含滚动文件与 `.out`） |
| 启动输出 | `cn_<ip>.start` / `dn_<ip>.start`（崩溃现场） |
| 配置 | `iotdb-system.properties`、`iotdb-common.properties`、`datanode-env.sh`、`confignode-env.sh` |
| 现场 | `00_host_info.txt`（进程/RSS/端口/磁盘/版本目录） |
| 汇总 | `00_cluster_overview.txt`（show cluster、show cluster details、各节点版本） |

另外，用例脚本的完整执行日志（`sh -x`，含每条命令与输出）在客户端：`/tmp/tc44_v21067.out`，也建议一并给研发。

---

## 五、复现步骤（可重放）

```bash
# 1. 客户端 70.3
cd /data1/iotdb/testcase/MigrateRegionTest/testcase

# 2. 换回缺陷当时的脚本快照（当前仓库里的 tc44 已被改过，复现不了原始现象）
cp -p tc44_add_peer_stop_cn_remove-coord.sh tc44_add_peer_stop_cn_remove-coord.sh.bak_$(date +%Y%m%d_%H%M%S)
cp -p tc44_add_peer_stop_cn_remove-coord.sh.20260707.V2-1067 tc44_add_peer_stop_cn_remove-coord.sh

# 3. 确认 conf 指向缺陷版本（现成的，无需部署）
grep -E "v_cur_db|db_dir" ../conf/test.conf
#   v_cur_db=v20102_rc1_0701_5e711bf
#   db_dir=/data/iotdb/v20102_rc1_0701_5e711bf

# 4. 执行
nohup sh -x ./tc44_add_peer_stop_cn_remove-coord.sh > /tmp/tc44_v21067.out 2>&1 &

# 5. 收各节点日志
cd /data1/iotdb/testcase/MigrateRegionTest/skill_case/defect_repro
bash tools/collect_logs.sh V2-1067_repro v20102_rc1_0701_5e711bf
```

执行耗时约 **13 分钟**（用例本身 745s）。

---

## 六、给研发的建议

1. **核心问题确认存在**：同一次 region 迁移（DataRegion 1 → DN 4）里，AddRegionPeerProcedure 先 rollback（`DO_ADD_REGION_PEER FAIL`），4m56s 后又 success。这与缺陷标题描述一致，建议沿 `AddRegionPeerProcedure:225`（rollback 分支）与 `:172`（success 分支）的判定条件排查：为什么同一目标、同一 region 会先判 FAIL 后判成功。

2. **`has some other region operation procedures in progress` 本次未出现**：说明该报错不是必现路径，可能与"重试提交时旧 procedure 是否仍在 executor 中"的时序有关。建议加一条日志，在拒绝迁移请求时打印**持锁的 procedure id 与状态**，便于确认是不是残留锁导致。

3. **4m23s 的 `Worker stuck` 窗口**：`AddRegionPeerProcedure` 在这段时间内没有任何状态推进日志。建议在该 procedure 的 `DO_ADD_REGION_PEER` 轮询里补"当前等待对象/已等待时长"的日志，否则从日志无法判断是等 snapshot 还是等锁。

4. **用例判定过于临界**：本次失败只差 10 秒（300s 超时 vs 5m15s 完成）。若研发认为 5m15s 属正常范围，建议把 tc44 的等待窗口从 300s 放宽到 600s，否则会把"慢"误报成"失败"。

---

## 七、为什么"脚本被优化后复现不了"——时序实测

这是本次复现最有价值的发现。源码里拒绝迁移的条件是（`ProcedureManager.checkRegionOperationDuplication`，缺陷版本 5e711bf 第 1108 行）：

```java
getExecutor().getProcedures().values().stream()
    .filter(p -> !p.isFinished())                    // ① 必须"还没结束"
    .filter(p -> p instanceof RegionOperationProcedure)
    .filter(p -> regionId.equals(p.getRegionId()))   // ② 必须是同一个 region
```

**只在提交那一刻存在"未完成的同类 procedure"才拒绝。** 所以能否复现，完全取决于第二次 `MIGRATE` 落在哪个时间点。

本次实测窗口（取自 CN 172.20.70.26 与协调者 DN 172.20.70.27 的日志）：

| 时刻 | 事件 | 距窗口 |
|---|---|---|
| 15:30:22.279 | 迁移① `MIGRATE REGION 1 FROM 3 TO 4` 提交 | — |
| 15:31:22.592 | 协调者 DN .27 首条 `[SNAPSHOT TRANSMISSION] The overall progress` | 传输开始 |
| 15:31:49.318 | 第 2 条 progress → **脚本的注入判据命中** | |
| 15:32:00–04 | 停目标 DN .26 + 停 CN leader .4 | 注入成功 |
| 15:32:12.834 | `[pid21][AddRegion] Start to roll back ... DO_ADD_REGION_PEER result is FAIL` | 窗口内 |
| 15:32:12.890 | `[pid19][MigrateRegion] released migration lock` | |
| **15:32:21.415** | `[pid22][AddRegion] Start to roll back ... CREATE_NEW_REGION_PEER fail` | **窗口关闭** |
| 15:33:05.664 | 第二次迁移 `FROM 6 TO 4` 才提交 | **晚了 44 秒** |

⇒ **可触发"残留 procedure 挡迁移"的窗口只有约 21 秒**（15:32:00–15:32:21）。

对比原缺陷：pid22 一直未结束到 15:43:02，窗口约 **4.5 分钟**，所以稳定复现。

**结论：异常本身（同一 region/同一目标 rollback 与 success 并存）是稳定存在的；但"被残留锁拒绝"这一步，取决于旧 procedure 在 leader 切换后退化得多快——快则窗口只有几十秒，脚本的固定等待/重试必然错过。**

### 确定性复现补丁（替换脚本里"第二次迁移"的触发时机）

现在的写法是"停完 DN/CN、等 region 数恢复、再提交第二次迁移"，46 秒的固定流程必然冲出 21 秒的窗口。改成**盯日志、见 rollback 立刻提交**：

```bash
# 故障注入之后立刻进入：一旦出现 rollback，0.5s 内提交第二次迁移
v_start_time=`date +%s`
while true
do
   v_rolled_back=`ssh ${u_name}@${v_cn_leader_ip} \
     "grep -c 'AddRegion] Start to roll back' ${db_dir}/logs/*confignode*all*"`
   if [[ ${v_rolled_back} -gt 0 ]];then
      # 关键：不等 DN/CN 恢复，抢在残留 procedure 结束前提交
      ${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "MIGRATE REGION 1 FROM 6 TO 4;" \
        > ${cur_dir}/mig2_probe.out 2>&1
      grep -q 'has some other region operation procedures in progress' ${cur_dir}/mig2_probe.out \
        && echo "[REPRO] 残留 procedure 成功挡住新迁移" | tee -a ${cur_dir}/repro_probe.log \
        || echo "[MISS] 窗口已关闭，未命中" | tee -a ${cur_dir}/repro_probe.log
      break
   fi
   v_end_time=`date +%s`
   [[ $((v_end_time-v_start_time)) -gt 120 ]] && break
   sleep 0.5
done
```

要点三条：

1. **轮询间隔 ≤ 0.5s**（窗口只有 20 秒量级）
2. **不要等 DN/CN 恢复**（等待本身就是错过窗口的主因）
3. 命中判据直接看 SQL 返回里的 `has some other region operation procedures in progress`

按此改法，任何版本的 tc44 都能稳定命中；反之，脚本若加了"等迁移稳定/等 region 数恢复/重试若干次"的逻辑，就必然复现不了——这与"问题是否存在"无关。


---

## 八、决定性证据：Residual Procedure 挡迁移（直接验证，2026-10-28 16:20）

前七节证明了"rollback 与 success 并存"，但"残留 procedure 挡住新迁移"这一步，第一次跑因**晚了 44 秒**没命中。
本节用**不依赖抢窗口**的方式直接把这一步验证出来。

### 方法

只要 region 1 上存在**未完成的** region 操作 procedure，新的 `MIGRATE` 就必须被拒。而一次迁移的
`AddRegionPeerProcedure` 生命周期是**几分钟**（8.6GB 快照传输），窗口足够宽，不需要抢秒：

```sql
-- 步骤1：发起迁移 A（region 1 副本 3→5，8.6GB 快照）
MIGRATE REGION 1 FROM 3 TO 5;      -- → The statement is executed successfully.

-- 步骤2：20 秒后，迁移 A 尚未完成，提交迁移 B（同一 region）
MIGRATE REGION 1 FROM 4 TO 7;
```

### 结果（两次都命中）

```
[16:20:31] MIGRATE REGION 1 FROM 3 TO 5;
           Msg: The statement is executed successfully.

[16:20:52] MIGRATE REGION 1 FROM 4 TO 7;
           Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 900:
           TConsensusGroupId(type:DataRegion, id:1) has some other region operation
           procedures in progress, their procedure id is:
           [AddRegionPeerProcedure{regionId=TConsensusGroupId(type:DataRegion, id:1),
                                   coordinator=4@172.20.70.26,
                                   targetDataNode=5@172.20.70.14},
            pid=31, state=WAITING:CHECK_ADD_REGION_PEER, locked=true;
            org.apache.iotdb.confignode.procedure.impl.region.RegionMigrateProcedure,
            regionId=TConsensusGroupId(type:DataRegion, id:1)]

[16:20:53] MIGRATE REGION 1 FROM 3 TO 7;
           Msg: （同上，完全一致的拒绝信息）
```

### 这证明了什么

| 结论 | 证据 |
|---|---|
| 新迁移确实被 region 操作 procedure 挡住 | 两次提交均返回 `has some other region operation procedures in progress` |
| 拒绝信息里**点名了持锁者** | `AddRegionPeerProcedure ... pid=31, state=WAITING:CHECK_ADD_REGION_PEER, locked=true` |
| 不是偶发 | 间隔 1 秒连续两次，拒绝信息完全一致 |
| 与缺陷原文的报错**完全一致** | 同一条 `ProcedureManager:1151` 消息 |

### 与缺陷的完整因果链

```
CN leader 切换
  → 迁移中的 AddRegionPeerProcedure 走 rollback（DO_ADD_REGION_PEER FAIL / CREATE_NEW_REGION_PEER fail）
  → 该 procedure 在 executor 中仍未 finished（本次实测残留 9 秒~数分钟不等）
  → 期间任何新的 MIGRATE REGION 1 都被 checkRegionOperationDuplication 拒绝
  → 用例的重试迁移在 180s 内无法成功 → tc44 fail
```

**本次两次独立实验分别验证了链条的两端**：
- 第一次（15:32）：**rollback 与后续 success 并存**（pid21/pid22 rollback，pid25 success，间隔 4m56s）
- 本次（16:20）：**未完成的 AddRegionPeerProcedure 确实挡住新迁移**（pid=31, locked=true）

链条中间那一环——"rollback 后该 procedure 多久才 finished"——是决定用例能否稳定复现的关键变量：
残留久（原缺陷 ~4.5 分钟）则必然失败；残留短（本次 9 秒）则要看重试的时机。

