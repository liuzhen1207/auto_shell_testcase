# 缺陷报告：反复 DROP TABLE / CREATE TABLE 导致 DataNode post-GC 堆持续增长（无平台）

| 项 | 内容 |
|---|---|
| 标题 | 反复 `DROP TABLE` / `CREATE TABLE` 导致 DataNode post-GC 堆持续增长，1000 轮未见平台 |
| 严重程度 | **P2**（内存不回收、无上限增长；触发条件是需要 DDL 反复建删的场景） |
| 影响版本 | **2.0.13.1 RC1**（build `ab6d3de`）、**2.0.12.1 RC10**（build `c60ce63`），两版本均可复现 |
| 测试环境 | 3 CN（172.16.2.16/17/18）+ 5 DN（172.16.2.19/21/22/23/24），SchemaRegion 3 副本 / DataRegion 2 副本，`IoTConsensus`，DN 堆 12 GB |
| 发现时间 | 2026-10-30 |
| 结论 | 数据删除路径不泄漏；**元数据（表）反复建删路径存在可复现的堆持续增长**，RC1 跑满 1000 轮仍无平台 |

## 一、现象

以「每轮：写入 100 设备数据 → `FLUSH`（每 10 轮）→ `DROP TABLE` → `CREATE TABLE`」循环执行，
每次循环后对 5 台 DataNode 执行 `jcmd <pid> GC.run` 并读 `GC.heap_info` 的 `used`（**强制 GC 后的稳态堆**），
随轮次推进单调上升且不收敛。

### RC1（2.0.13.1，`ab6d3de`，1000 轮 × 100 设备）

| DN | 100 轮后 | 1000 轮后 | 增长 | 斜率 |
|---|---:|---:|---:|---:|
| .19 | 76,620 KB | 118,249 KB | +41,629 KB | **+46.3 KB/轮** |
| .21 | 71,793 KB | 134,602 KB | +62,809 KB | **+69.8 KB/轮** |
| .22 | 69,408 KB | 115,824 KB | +46,416 KB | **+51.6 KB/轮** |
| .23 | 70,131 KB | 114,769 KB | +44,638 KB | **+49.6 KB/轮** |
| .24 | 77,936 KB | 173,262 KB | +95,326 KB | **+105.9 KB/轮** |

5 台 DN 全部单调上升，900 轮内增长 44～95 MB，**没有任何走平迹象**。按均值 ~65 KB/轮外推，10 万次 DDL 约 6.5 GB 堆增长。

### RC1 追加 2000 轮：确认无平台（2026-11-02）

为排除"最终会在更高水位平台化"，同一用例在 RC1 上再跑 **2000 轮**（100 设备/轮，每 50 轮采样，共 41 个采样点）：

| DN | 100 轮 | 1000 轮 | 2000 轮 | 100→2000 总增长 |
|---|---:|---:|---:|---:|
| .19 | 80,893 KB | 124,694 KB | 178,739 KB | +97.8 MB |
| .21 | 86,322 KB | 143,405 KB | 188,955 KB | +102.6 MB |
| .22 | 71,269 KB | 120,720 KB | 168,322 KB | +97.1 MB |
| .23 | 71,841 KB | 117,993 KB | 167,295 KB | +95.5 MB |
| .24 | 86,446 KB | 176,521 KB | 258,182 KB | +171.7 MB |

**分段斜率（KB/轮）——最后 500 轮仍在增长，斜率无衰减**：

| DN | 100-500 | 500-1000 | 1000-1500 | 1500-2000 | 全程 |
|---|---:|---:|---:|---:|---:|
| .19 | 53.8 | 44.5 | 49.3 | **58.8** | 51.5 |
| .21 | 62.4 | 64.3 | 34.3 | **56.8** | 54.0 |
| .22 | 70.9 | 42.2 | 48.3 | **46.9** | 51.1 |
| .23 | 55.2 | 48.1 | 50.4 | **48.2** | 50.2 |
| .24 | 111.6 | 90.9 | 82.6 | **80.7** | 90.4 |

DN24 的分段斜率有轻微收敛（112→91→83→81），但到 2000 轮仍以 ~81 KB/轮持续增长，与走平相差极远；其余 4 台在 1000-2000 轮区间甚至略回升。**2000 轮内不存在平台，泄漏结论成立。**

### RC10（2.0.12.1，`c60ce63`，200 轮 × 100 设备，同一用例 4 次独立运行）

| 运行 | DN19 | DN21 | DN22 | DN23 | DN24 |
|---|---:|---:|---:|---:|---:|
| #1 | -16.5 | **+198.7** | +9.2 | **+142.9** | **+104.5** |
| #2 | +18.7 | **+102.4** | **+181.5** | **+93.2** | +20.9 |
| #3 | +12.4 | **+103.9** | **+169.2** | **+97.8** | +22.1 |
| #4 | +6.7 | **+89.4** | **+161.6** | **+118.5** | -36.4 |

（KB/轮，40~200 轮拟合，单位同上）四次运行形态一致：承载该表 DataRegion 的 2~3 台 DN 持续增长。

## 二、对照组：纯数据删除不泄漏

同样的测量方法，只做数据删除、不做 DDL：

| 用例 | 场景 | 斜率范围 | 结论 |
|---|---|---:|---|
| DEL-MEMLEAK-TABLE-001 | 按 WHERE 删除（200 轮） | -13.0 ~ +33.6 KB/轮 | 走平 |
| DEL-MEMLEAK-TABLE-002 | 全量删除（200 轮） | -21.0 ~ +28.3 KB/轮 | 走平 |
| DEL-MEMLEAK-TREE-001 | 树模型 WHERE 删除（200 轮） | -3.6 ~ +31.9 KB/轮 | 走平 |
| DEL-MEMLEAK-TREE-002 | 树模型全量删除（200 轮） | -13.4 ~ +67.9 KB/轮 | 走平 |

说明增长来自 **DDL（DROP/CREATE TABLE）路径**，不是 DELETE 本身。

## 三、复现步骤

环境：3C5D，DN 堆 12 GB，`data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus`。

```bash
# 0) 脚本在测试机 172.16.2.20
BASE=/data2/iotdb/rc10_matrix

# 1) 重置集群到干净状态并启动（脚本会停 8 节点、校验进程归零、清 data/logs、并行启动、等 8/8）
NEW=/data1/iotdb/v20131rc1_1030_ab6d3de bash $BASE/scripts/cluster_ctl.sh reset

# 2) 跑 1000 轮「写 100 设备 → FLUSH(每10轮) → DROP TABLE → CREATE TABLE」
#    每 50 轮对 5 台 DN 执行 jcmd GC.run 后采 GC.heap_info 的 used
NEW=/data1/iotdb/v20131rc1_1030_ab6d3de \
CLI=/data2/iotdb/v20131rc1_1030_ab6d3de/timechodb-2.0.13.1-bin/sbin/start-cli.sh \
RUN_TAG=rc1 CYCLES=1000 DEVICES=100 EVERY=50 \
bash $BASE/scripts/memleak_study.sh DEL-MEMLEAK-TABLE-003

# 3) 出稳态斜率（剔除预热段）
WARM=100 bash $BASE/scripts/memleak_analyze.sh
```

等价的裸 SQL（单轮）：

```sql
SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_mls_table;
CREATE TABLE del_rc10_mls_table.t (device_id STRING TAG, v INT32 FIELD);
-- 100 条 INSERT，时间戳递增
DROP TABLE del_rc10_mls_table.t;
CREATE TABLE del_rc10_mls_table.t (device_id STRING TAG, v INT32 FIELD);
-- 重复 1000 次；每 10 轮 FLUSH 一次
```

## 四、测量方法（可复核）

1. 每轮结束后在**每台 DataNode** 上执行 `jcmd <pid> GC.run`，再读 `jcmd <pid> GC.heap_info` 的 `used`（garbage-first heap used）。
   > 注意：不能用进程 RSS 判定。同一次运行 RSS 从 858 MB 涨到 1,486 MB（+628 MB），但强制 GC 后堆仅 47→82 MB 且很快走平；RSS 含已提交未使用堆，GC 不回落。
2. **剔除预热段**：前 100 轮不计入拟合（RC1）/ 前 40 轮（RC10 的 200 轮试验），只对稳态段做线性回归。
3. 采样间隔 50 轮（RC1）/ 20 轮（RC10），每点 5 台 DN。
4. 原始数据、每轮 SQL 与输出全部落盘（见第六节）。

## 五、附加观察

- **RC1 的 DDL 明显更慢**：100 设备/轮 = 100 条 INSERT + DROP + CREATE，RC1 上约 12 秒/轮，RC10 上约 2.5 秒/轮。
  疑似与元数据路径相关，建议一并排查（此项为观察，未单独定量）。
- 树模型元数据（`DELETE TIMESERIES` / `CREATE TIMESERIES`）同样呈增长趋势，但 RC1 那次为控制时长把每轮设备数从 100 降到 10，与 RC10 的 100 设备不可直接比较，故未作为主结论。

## 六、证据位置

测试机 `172.16.2.20:/data2/iotdb/rc10_matrix/`

| 路径 | 内容 |
|---|---|
| `studies/DEL-MEMLEAK-TABLE-003-rc1/post-gc-heap.csv` | RC1 1000 轮：21 个采样点 × 5 台 DN 的 post-GC 堆与 RSS |
| `studies/DEL-MEMLEAK-TABLE-003-rc1/study.log` | RC1 运行日志（含每轮耗时） |
| `studies/DEL-MEMLEAK-TABLE-003{,-rep1,-rep2,-rep3}/` | RC10 的 1 次正式 + 3 次复测原始数据 |
| `studies/DEL-MEMLEAK-TABLE-00{1,2}/`、`DEL-MEMLEAK-TREE-00{1,2}/` | 对照组（纯数据删除）数据 |
| `studies/analysis.txt` | 全部用例的稳态斜率汇总 |
| `logs/rc1-1000.log` | RC1 1000 轮完整执行日志 |

## 七、影响与建议

**影响**：长时间运行且存在表生命周期管理（反复建表/删表）的集群，DataNode 堆会持续上涨，最终触发 Full GC 频繁甚至 OOM；当前 12 GB 堆下，约 10 万次 DDL 量级才会明显逼近上限，属"慢性"问题而非立即故障。

**建议排查方向**：

1. `DROP TABLE` 时 schema/TsFile/region 元数据是否被完整释放（表级缓存、TsFileResource、mods 文件句柄等）；
2. DataRegion 的元数据缓存是否以表为 key 且无淘汰；
3. 结合第五节"RC1 DDL 更慢"一起看，可能是同一处元数据累积导致。

**临时规避**：控制 DDL 频率；对长期运行集群定期滚动重启 DataNode。

## 八、局限

- 已追加 RC1 2000 轮复核，**排除了"最终平台化"**：最后 500 轮斜率仍为 46.9～80.7 KB/轮，全程无走平。
- 单机 5 DN 的 3C5D 环境，未在生产规模数据量下验证；未做 heap dump 定位具体持有链（需研发侧 MAT 分析）。
