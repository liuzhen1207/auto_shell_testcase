# tc54_add_peer_residual_lock.sh —— V2-1067 专用回归用例

## 为什么新增，而不是沿用 tc44

| 方案 | 能否稳定复现 V2-1067 | 说明 |
|---|---|---|
| `tc44_add_peer_stop_cn_remove-coord.sh`（当前版本） | ❌ | 已做"优化"：故障注入后走固定流程（等 DN/CN 恢复、等 region 副本数回到 2、再带重试地提交第二次迁移），整个流程 40s+，而残留窗口实测只有 **20 秒量级**，必然错过 |
| `tc44_...sh.20260707.V2-1067`（缺陷当时快照） | ⚠️ 只复现一半 | 能复现"rollback 与 success 并存"；"被残留锁挡住"这一步靠运气（取决于旧 procedure 多久 finished）。且文件名不符合 `tc<num>_` 规范，不能直接登记 |
| **`tc54_add_peer_residual_lock.sh`（本次新增）** | ✅ | 保留 tc44 的场景与造数，仅把"第二次迁移"改成**日志驱动 + 0.5s 轮询 + 全 CN 监听**，命中即判 FAIL |

## 与 tc44 快照的差异（仅 +46 行，一处插入）

插入位置：故障注入并确认 DN/CN 停止之后、等待 region 副本数恢复之前。

```bash
# 全 CN 监听 AddRegionPeer rollback，0.5s 间隔
for v_cn_h in `cat ${nodeinfo_dir}/confignode.txt`; do
   v_rb_one=`ssh ... "sudo grep -h 'AddRegion] Start to roll back' ${db_dir}/logs/*confignode*all* | wc -l"`
   v_rb_total=$((v_rb_total + ${v_rb_one:-0}))
done
# 检测到 rollback 立刻提交重试迁移
${cli_dir}/sbin/start-cli.sh -h ${query_ip} -e "MIGRATE REGION ${v_mig_id} FROM ${v_mig_from_dn_id} TO ${v_mig_to_dn_id};" > ${cur_dir}/probe_mig.out 2>&1
# 被判据命中 → 缺陷复现 → 用例 FAIL
grep -q "has some other region operation procedures in progress" ${cur_dir}/probe_mig.out && let fail_flag++
```

关键点（都是实测踩出来的）：

1. **轮询 ≤0.5s** —— 窗口 20 秒量级
2. **不能只盯一台 CN** —— 实测新 leader 出现在 `.5`，而第一次只盯 `.26` 导致漏检
3. **不要等 DN/CN 恢复再提交** —— 等待本身就是错过窗口的主因
4. **不要用 `bc` 做计数** —— 测试机未装 `bc`，会让计数恒为空、探针静默失效

## 用例语义

- **缺陷存在（v20102_rc1_0701_5e711bf）** → 探针命中 → `fail_flag++` → 用例 **FAIL**
- **缺陷修复后** → 重试迁移不被拒 → 探针记"未被挡" → 用例按常规流程判 **PASS**

## 产物位置

| 项 | 路径 |
|---|---|
| 用例脚本 | `testcase/tc54_add_peer_residual_lock.sh`（已推送并登记） |
| 用例清单 | `testcase/migrate_testcase_list.txt`（已插入到 `tc53_mig_comping.sh` 之后） |
| 探针日志 | 运行时写 `testcase/probe_residual_lock.log`、`testcase/probe_mig.out` |

---

## 验证结果：首跑即命中（2026-10-28）

用 `v20102_rc1_0701_5e711bf` 实跑一次 tc54，**探针首跑命中**：

```
[2026-10-28 16:56:14] 开始监听 AddRegionPeer rollback（全部 CN，0.5s 间隔）
[2026-10-28 16:56:17] 检测到 rollback（累计 1 次），立即提交重试迁移 1: 3 -> 4
                      Msg: IoTDBSQLException: 900: TConsensusGroupId(type:DataRegion, id:1)
                      has some other region operation procedures in progress, their procedure id is:
                      [AddRegionPeerProcedure{regionId=..., coordinator=6@172.20.70.27,
                       targetDataNode=4@172.20.70.26}]
[2026-10-28 16:56:22] ★ V2-1067 复现：重试迁移被残留 procedure 挡住（Region 操作锁未释放）
```

- 从"开始监听"到"命中"仅 **3 秒**，证明 0.5s 轮询足够；
- 用例最终判定：`tc54_add_peer_residual_lock.sh : fail`（**fail_flag=1**）；
- 该 FAIL 是**期望结果**——缺陷存在于该版本时用例就应该失败。

对照：同一版本下 `tc44_add_peer_stop_cn_remove-coord.sh`（优化后版本）最近一次为 **pass**，
即**旧用例已无法检出该缺陷，tc54 可以**。

## 证据文件

| 文件 | 内容 |
|---|---|
| `docs/probe_residual_lock_20261028.log` | 本次探针完整时间线与命中的原始 SQL 返回 |
| `testcase/probe_residual_lock.log`（70.3） | 同上，运行现场 |
