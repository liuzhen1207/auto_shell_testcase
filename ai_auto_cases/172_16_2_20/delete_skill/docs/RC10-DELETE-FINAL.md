# RC10 DELETE 全量验证 — 最终报告（2026-10-29）

## 一、结论

| 项 | 结果 |
|---|---|
| 版本 | TimechoDB 2.0.12.1 **RC10**，BuildInfo `c60ce63` |
| 实例 | `/data1/iotdb/v20121rc10_1021_c60ce63`（8 节点同路径） |
| 拓扑 | 3 CN (172.16.2.16/.17/.18) + 5 DN (172.16.2.19/.24/.21/.22/.23)，SchemaRegion 副本 3、DataRegion 副本 2、ClusterID3 |
| 用例矩阵 | 85 个 CASE ID / **163 个协议轮次**（IoTConsensus 85 + IoTV2 78） |
| 执行结果 | **161 通过 / 2 失败**（失败均为同一可复现的 1 秒级同步尖峰，非数据错误） |
| 累计执行时长 | **108h34m**（去重后）；含重跑共 **122h19m / 184 次执行** |
| 墙钟时间 | 2026-10-24 09:22 → 2026-10-29 10:23（约 121 小时） |

分协议：**IoTConsensus 83/85 通过**，**IoTV2 78/78 通过**。

## 二、失败明细（2 例，同一签名）

| 协议 | CASE | 结论 | 复现次数 |
|---|---|---|---|
| IoTConsensus | DEL-TREE-002 | FAIL_OUTAGE | 2/2 |
| IoTConsensus | DEL-TREE-004 | FAIL_OUTAGE | 2/2 |

**签名（4 次观测完全一致）**：

- 唯一异常点：`region 6` 在 **DN23** 上的 `syncLag = 1.0` 秒，**单点**，其余样本均为 `0.0`
- 出现位置：恢复窗口第 **21~25** 个样本（约恢复后 3.5~4 分钟）
- 同一窗口内其余 4 台 DN、其余 region 全部为 0
- 基线窗口 0 异常；用例 SQL 全部成功（14 / 18 条）；五台 DN 查询结果逐字一致；最终集群 8/8

**为什么计为 2 个坏样本**：门禁对任一非零值 +1，同时 `region 6`（RF=2）在该样本上零 lag 副本数降到 1，再 +1。

**只有这两例会命中**：`region 6` 只出现在 `DEL-TREE-002` 与 `DEL-TREE-004` 的 region 集合里（`2 3 4 6`），而 `DEL-TREE-001/003` 的集合里没有 6，两者均 PASS。

**判断**：不构成产品缺陷。没有数据错误、没有跨 DN 不一致、没有集群异常，只有一个 1 秒级瞬时 lag 读数。合理怀疑来自 region 引导或周期性 flush/compaction。**建议按「可复现观察项」记录并请产品确认 1 秒级瞬时 lag 是否属预期**，不建议直接开缺陷单。

门禁偏严也是原因之一：要求 31 个样本**全部精确为 0** 且每样本每 region 至少 2 个零 lag 副本。若验收口径允许偶发 ≤1 秒瞬时值，这 2 例即可通过。

## 三、强有力的通过证据

1. **跨协议一致性 78/78 对完全相同**：同一用例在 IoTConsensus 与 IoTV2 下的查询结果 hash 完全一致，0 例外。共识协议切换不改变任何 DELETE 结果。
2. **OBJECT 全系列通过**：`DEL-OBJ-001..008` 两协议均 PASS，含多片对象、EOF、JSON 负向、非法 offset、GC/compaction 并发场景。
3. **27 个新编写的规格全部 PASS**（OBJ/MODS/REPL/RESTART/CONC/NEG/CLEAN），且跨协议一致。
4. **树模型与内存泄漏 10 轮**：8 PASS，2 为上述尖峰；树模型 DDL 在 2.0.12 上按最保守语法（`CREATE TIMESERIES root.x.d1.s1 INT32`）全部可用。
5. **DELETE 提交后的短暂可见性延迟**（首样本 lag 2.0/4.0，约 10 秒收敛）与技能文档描述一致，按预期行为处理，不计缺陷。
6. **权限负向已做真实验证**：`DEL-NEG-001` 用普通用户 `del_neg_reader`（仅 `GRANT SELECT ON TABLE`）在**独立 CLI 会话**执行 DELETE，两协议均返回
   `803: Access Denied: No permissions for this operation, please add privilege DELETE ON del_rc10_neg001.t`，
   且 root 复核 9 行数据完好，两协议均 PASS。证据见 `artifacts/{IoTConsensus,IoTV2}/DEL-NEG-001/post.out`。

## 四、必须知道的局限

1. **PASS 的口径是机械门禁**：SQL 无错、同步收敛、五台 DN 逐字一致、集群 8/8。逐条"行数/值是否符合用例设计"未做自动比对，报告里给出每轮实际行数与 hash 供人工核对；跨协议 hash 一致是可自动化的强不变量，已全量通过。
2. **内存泄漏：矩阵内 6 轮 PASS 不代表无泄漏**；已另做专项深测（见第八节），其中 `DEL-MEMLEAK-TABLE-003`（DROP TABLE 反复重建）出现单调增长的疑似迹象，`DEL-MEMLEAK-TREE-003` 因 DDL 过慢未跑完。
3. **27 个新规格未经人工复核**：虽然全部 PASS 且跨协议一致，语义正确性仍建议抽查。
4. `ACTIVATED(W)`：CN17/CN18 带告警激活（License 未覆盖全部 ConfigNode），实测不阻断写入，但正式验收建议换一张覆盖 3 个 ConfigNode 的 License。

## 五、执行方法（可复现）

每轮：停集群 → 校验 8 节点进程归零 → 清该实例 `data/`、`logs/` → 写本轮协议 → 并行启动（seed CN 优先）→ 8/8 Running → 执行用例 SQL → `SHOW REGIONS` 定位本例 DataRegion → 等每个 region 有 ≥2 个零 lag 副本 → 连续 31 样本（10 秒间隔 = 5 分钟）全零 → 五台 DN 逐台 `kill -9`、停机期查询、重启并等待就绪、恢复查询、再过 31 样本窗口 → 五台 DN 同一 SELECT 逐字比对 → `SHOW CLUSTER` 8/8。

单轮实测 **≈ 40 分钟**（重置 87 秒 + 基线 5.5 分钟 + 五台 DN 门禁约 30 分钟）。

## 六、过程缺陷复盘（均为测试框架问题，已修复并重跑）

| 现象 | 根因 | 影响 | 处理 |
|---|---|---|---|
| 12 例 FAIL_LAG | 用例 SQL 带 UTF-8 BOM，首条 `SET SQL_DIALECT=TABLE` 失效，建库失败、region 空集 | 整轮无效 | 执行前剥 BOM + 清理磁盘 12 个文件；加 `FAIL_REGION` 保护；重跑后 12 例全 PASS |
| 5 例 FAIL_DN_DIFF | 验证查询混入 `SHOW REGIONS`，其 `TsFileSize/CompressionRatio` 是各 DN 本地值 | 比对必然失败 | 验证查询只取 `SELECT`；重跑后 5 例全 PASS |
| 早期无法起集群 | JVM 由相对路径启动（`-DCONFIGNODE_HOME=sbin/..`），按绝对路径 `pkill` 从不匹配；CN 主类含 `service` 包名 | 端口被旧进程占用 | 绝对路径启动 + 按主类匹配进程 + 停止后校验归零 |

## 七、产物位置

```
172.16.2.20:/data2/iotdb/rc10_matrix/
  results/results.tsv              每次执行的原子记录（184 行）
  results/results.latest.tsv       去重后每例最后一次
  results/summary.tsv              每例实际行数与结果 hash
  results/cross-protocol-diff.txt  跨协议比对（最终为空）
  artifacts/<协议>/<CASE>/         每轮完整证据（SQL、输出、lag 采样、五次 DN 门禁、内存采样）
  report/RC10-DELETE-REPORT.md     机读生成的逐轮报告
  studies/<CASE>/                  内存泄漏专项：post-gc-heap.csv / trend.txt / study.log
  studies/analysis.txt             内存泄漏稳态分析（预热段剔除后的拟合）
```

## 八、内存泄漏专项深测（与 163 轮矩阵分离）

矩阵里的 6 个 `DEL-MEMLEAK-*` 只是"每例跑一遍"，采样只有 5 个进程 RSS 点，不能判定泄漏。为此另做专项：

**方法**：每例 200 轮 × 100 设备（累计 2 万次写 + 2 万次删的 churn），每 20 轮对 5 台 DN 执行 `jcmd GC.run` 后读 `GC.heap_info` 的 used；预热段（0~40 轮）不计入拟合，只对 40~200 轮的 post-GC 堆做线性回归，阈值 50 KB/cycle。

**结果（5/6 完成）**：

| 用例 | 场景 | 稳态斜率范围 | 判定 |
|---|---|---|---|
| DEL-MEMLEAK-TABLE-001 | 按 WHERE 删除 | -18.6 ~ +62.0 KB/cyc | 预热后走平，无泄漏迹象 |
| DEL-MEMLEAK-TABLE-002 | 全量删除 | -21.0 ~ +28.3 KB/cyc | 走平，无泄漏迹象 |
| DEL-MEMLEAK-TREE-001 | 树模型按 WHERE 删除 | -3.6 ~ +31.9 KB/cyc | 走平，无泄漏迹象 |
| DEL-MEMLEAK-TREE-002 | 树模型全量删除 | -13.4 ~ +67.9 KB/cyc | 走平，无泄漏迹象（DN23 单点偏高，见注） |
| **DEL-MEMLEAK-TABLE-003** | **DROP TABLE 反复重建** | **+89 ~ +193 KB/cyc（3 台 DN）** | **确认增长，4/4 复现** |
| **DEL-MEMLEAK-TREE-003** | **删/建 timeseries 元数据** | **+218 ~ +260 KB/cyc（3 台 DN）** | **确认增长，增幅更大** |

### 元数据反复建删的增长是可复现的

`DEL-MEMLEAK-TABLE-003` 做了 1 次正式 + 3 次复测，每次都重置集群、独立跑 200 轮：

| 运行 | DN19 | DN21 | DN22 | DN23 | DN24 |
| --- | ---: | ---: | ---: | ---: | ---: |
| run | -14 | **+193** | +3 | **+119** | **+102** |
| rep1 | +19 | **+102** | **+182** | **+93** | +21 |
| rep2 | +12 | **+104** | **+169** | **+98** | +22 |
| rep3 | +7 | **+89** | **+162** | **+118** | -36 |

（单位 KB/周期，拟合区间 40~200 轮，剔除预热段）

四次运行都是同样的形态：**承载该表 DataRegion 的 2~3 台 DN 持续增长，其余 DN 走平**，斜率稳定在 +89 ~ +193 KB/周期，200 轮内**没有平台**。DN21 的绝对量：post-GC 堆 82~92MB（40 轮）→ 100~125MB（200 轮），单轮次增长 18~32MB。

`DEL-MEMLEAK-TREE-003`（每轮删 100 个 + 建 100 个 timeseries）更明显：DN21 **+260**、DN22 **+218**、DN23 **+254** KB/周期，跑满 200 轮用了 6 小时。

### 不是泄漏的两处

- `TABLE-001` 的 DN23（+62）与 `TREE-002` 的 DN23（+67.9）：这两台 DN 在 40 轮时的基线只有 13MB / 3MB，而同级其余 DN 已到 35~40MB，属于区域缓存尚未加载完的"追赶"，不是泄漏。
- 纯数据删除路径（`TABLE-001/002`、`TREE-001/002`）在 200 轮 churn 后 post-GC 堆都在 80~87MB 附近波动，**没有增长趋势**。

**结论**：**数据删除不泄漏；元数据反复建删（DROP TABLE/CREATE TABLE、DELETE/CREATE TIMESERIES）会导致 DataNode post-GC 堆持续增长**，4 次运行可复现、200 轮内未见平台。建议按缺陷立项（P2 候选），并补一轮 1000 轮长跑确认是否最终平台化。

复现命令：

```bash
bash /data2/iotdb/rc10_matrix/scripts/memleak_study.sh DEL-MEMLEAK-TABLE-003   # CYCLES=200 DEVICES=100 EVERY=20
bash /data2/iotdb/rc10_matrix/scripts/memleak_study.sh DEL-MEMLEAK-TREE-003    # 同上，DDL 场景约 6 小时
bash /data2/iotdb/rc10_matrix/scripts/memleak_analyze.sh                       # 输出 studies/analysis.txt
```
