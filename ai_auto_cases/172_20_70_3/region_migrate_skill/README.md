# region_migrate_skill —— Region 迁移专项用例（V2-1067 复现）

> **位置**：`ai_auto_cases/172_20_70_3/region_migrate_skill/`
> **执行机**：172.20.70.3　**依赖**：**MigrateRegionTest 框架**（见下）

## ⚠️ 与其他 skill 不同：本用例依赖外部框架

`cases/tc54_add_peer_residual_lock.sh` 是从 `MigrateRegionTest/testcase/` 的 tc44 派生而来，
运行时需要 MigrateRegionTest 框架提供：

```
MigrateRegionTest/
├── conf/test.conf          # 版本目录、节点清单、SSH 用户
├── conf/confignode.txt     # CN 列表
├── clean_env/              # stop_cluster.sh / clean_cluster.sh / reset_conf.sh
└── testcase/tc54_add_peer_residual_lock.sh   ← 本文件放这里
```

即：把 `cases/tc54_add_peer_residual_lock.sh` 拷到 `MigrateRegionTest/testcase/` 下运行，
**不是**像 `memory_buffer_skill` 那样自带 `lib/` 的独立 skill。

## 缺陷背景

| 项 | 内容 |
|---|---|
| 缺陷 | PingCode **V2-1067**（V2.0.12.1 / RC1） |
| 现象 | CN leader 切换后，同一轮 Region 1 迁移中 AddRegionPeerProcedure 出现 rollback/fail 与后续 success 并存；残留 procedure 占用 Region 操作锁，导致重试迁移失败 |
| 发现版本 | `v20102_rc1_0701_5e711bf` |
| 复现报告 | [docs/V2-1067_REPRO.md](docs/V2-1067_REPRO.md) |
| 用例说明 | [docs/CASE_tc54.md](docs/CASE_tc54.md) |

## 用例设计要点

原 tc44 已"优化"，故障注入后走固定流程（等 DN/CN 恢复、等副本数回到 2、再带重试提交第二次迁移），
全程 40s+，而实测残留窗口只有 **20 秒量级**，必然错过。tc54 只改一处——**把第二次迁移改成日志驱动**：

1. **轮询 ≤0.5s**（窗口 20 秒量级）
2. **同时查所有 CN**（新 leader 可能是任意一台，实测曾出现在非首个 CN）
3. **检测到 rollback 立刻提交**，不等 DN/CN 恢复
4. **不用 `bc` 计数**（测试机未装，会让探针静默失效）——改用 `wc -l`

命中判据：重试迁移返回 `has some other region operation procedures in progress` → 即缺陷复现 → 用例 FAIL。

## 实测

`v20102_rc1_0701_5e711bf` 上首跑即命中（3 秒内），用例判定 `fail`（期望结果）：

```
[16:56:14] 开始监听 AddRegionPeer rollback（全部 CN，0.5s 间隔）
[16:56:17] 检测到 rollback（累计 1 次），立即提交重试迁移 1: 3 -> 4
           IoTDBSQLException: 900: ... has some other region operation procedures in progress ...
[16:56:22] ★ V2-1067 复现：重试迁移被残留 procedure 挡住（Region 操作锁未释放）
```

对照：同版本下优化后的 `tc44` 最近一次为 `pass`，即**旧用例已检不出该缺陷**。

## 运行

```bash
# 1) 放到 MigrateRegionTest 框架下
cp cases/tc54_add_peer_residual_lock.sh /data1/iotdb/testcase/MigrateRegionTest/testcase/
cd /data1/iotdb/testcase/MigrateRegionTest/testcase

# 2) 确认 conf 指向缺陷版本
grep -E "v_cur_db|db_dir" ../conf/test.conf

# 3) 执行（约 15 分钟）
nohup sh -x ./tc54_add_peer_residual_lock.sh > /tmp/tc54.out 2>&1 &

# 4) 收各节点完整日志
bash <本 skill>/tools/collect_logs.sh V2-1067 v20102_rc1_0701_5e711bf
```

## 工具

`tools/collect_logs.sh` —— 采集 3 CN + 5 DN 的完整日志（含 `logs_stop_remove_coord_*`
这种被用例 mv 走的故障瞬间日志）、配置四件套、进程/端口/磁盘现场，打包给研发。
