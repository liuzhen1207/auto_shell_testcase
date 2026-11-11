# 2.0.13.1 RC2 + DataRegion=IoTConsensusV2 回归报告

| 项目 | 内容 |
| --- | --- |
| 构建 | TimechoDB **2.0.13.1 / `83183d0`（RC2）** |
| 数据面协议 | **`org.apache.iotdb.consensus.iot.IoTConsensusV2`**（`SHOW VARIABLES` 实测确认） |
| 集群 | 3 CN（172.16.2.26/27/28）+ 5 DN（172.16.2.2~6），schema 3 副本 / data 2 副本 |
| 执行时间 | 2026-11-11 12:11 ~ 14:27 |
| 用例总数 | **248 条**（tree_view 67 + releasenote 147 + auth 34） |
| 结果目录 | `/data2/auto_test/v2_results_20261111_121053` |
| 结论 | **与 IoTConsensus 基线完全一致，无新增缺陷** |

---

## 一、协议切换方法（已验证）

`data_region_consensus_protocol_class` 在 **CN 与 DN 两侧都存在**，而 `SHOW VARIABLES` 读的是 **CN** 的值 —— 只改 DN 不会生效（本次踩过）。

```bash
# 1) CN + DN 都写入
data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensusV2
# 2) 必须清数据重建（协议在建 region 时确定）
# 3) 校验
SHOW VARIABLES;   -- DataRegionConsensusProtocolClass = ...IoTConsensusV2
```

已更新 `releasenote_skill/tools/mode.sh` 的 `proto-v2` / `proto-iot` 分支（CN+DN 双写），并修正了 `hard_reset.sh` 的相对路径。

## 二、总览

| 技能 | 用例 | PASS | FAIL | KNOWN | SKIP |
| --- | ---: | ---: | ---: | ---: | ---: |
| tree_view | 67 | **59** | 8（全部可解释） | 0 | 0 |
| releasenote | 147 | **130** | 0 | 1 | 16 |
| auth | 34 | **34** | 0 | 0 | 0 |

## 三、与 IoTConsensus 基线对比

| 技能 | IoTConsensus（2026-11-10 夜） | IoTConsensusV2（本次） | 差异 |
| --- | --- | --- | --- |
| tree_view | 59 PASS / 8 FAIL | 59 PASS / 8 FAIL | 无 |
| releasenote | 130 PASS / 1 KNOWN / 16 SKIP | 130 PASS / 1 KNOWN / 16 SKIP | 无 |
| auth | 34 PASS / 0 FAIL | **normal 27/27 + separation 34/34 全 PASS** | 无 |

**TDB-343 树转表自动扩列 70 条用例在 V2 下全部通过**（含故障注入、多级存储、并发、权限、日志机密性）。

## 四、tree_view 的 8 个失败（逐条归因）

| 用例 | 现象 | 归因 |
| --- | --- | --- |
| TV-080 / TV-081 / TV-082 / TV-088 | 改名后视图 TAG 仍为旧名 / 跨库改名后 0 行 / 重启后仍旧名 | **TDB-888**（已知缺陷，未修复，与协议无关） |
| TV-015 / TV-031 / TV-060 | `logERROR=N`（`ViewColumnAutoSyncTrigger` 552/305、隔离期间 `openSession` 失败） | **TDB-890**（已知，功能正确、日志异常）+ HA 噪声 |
| TV-055 | kill -9 DN 后建序列返回 `503 Path already exist` | **瞬时**：单独复跑 **3/3 PASS**（96s/76s/76s），仅在全量连跑时受前一个 HA 用例残留影响 |

## 五、过程中的两个坑（已在脚本中修复）

1. **只改 DN 不生效**：`mode.sh proto-v2` 原来只写 DN 的 `iotdb-system.properties`，
   但 `SHOW VARIABLES` 取的是 CN 的 `ConfigNodeConfig.dataRegionConsensusProtocolClass`，
   表现为"配置已写、协议没变"。→ 已改为 **CN + DN 双写**。
2. **两套回归并发互杀**：11:12 那次启动的 tree_view 未真正被杀掉，与 11:29 新启动的套件并发运行，
   两边的 HA 用例互相 `kill -9` 节点，导致集群崩掉、出现大面积假失败（当时 18 例里 10 例 FAIL）。
   → 已在 `v2_suites.sh` 加启动前残留检查；清理后同一套用例 **59/67**，与基线一致。

> 复核依据：并发期间 `ps` 显示两个 `tools/suite.sh`（etime 54min 与 38min），
> DN 日志里是 `Conflict is detected in directory ... ProcessId=xxxxx`（重复启动同一数据目录），
> 并非 V2 的稳定性问题。

## 六、结论

1. **IoTConsensusV2 下功能表现与 IoTConsensus 完全一致**：248 例结果逐项对齐，无新增缺陷；
2. TDB-888（改名同步）、TDB-1049（DN 无响应期间丢列）、TDB-890（补列日志 ERROR）在 V2 下**同样存在**，
   说明这些是元数据/视图层问题，与数据面协议无关；
3. 协议切换成本：需改 CN+DN 配置并**清数据重建**，升级已有集群需走迁移方案（本次未验证，属独立课题）。

## 七、复现

```bash
# 切协议（CN+DN 双写 + 清数据重建）
cd /data2/auto_test/releasenote_skill && NEW=v20131rc2_1110_83183d0 bash tools/mode.sh proto-v2
# 校验
start-cli -e "show variables" | grep DataRegionConsensusProtocolClass

# 三段回归（单实例运行，脚本自带残留检查）
bash /tmp/v2_suites.sh v20131rc2_1110_83183d0
```

> 切回 IoTConsensus：`bash tools/mode.sh proto-iot`（同样会清数据重建）。
