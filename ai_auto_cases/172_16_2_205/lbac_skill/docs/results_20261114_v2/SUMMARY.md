# LBAC 在 IoTConsensusV2 下的双模式结果（160 条，2026-11-14）

| 项目 | 内容 |
| --- | --- |
| 版本 | 2.0.13.1 / `83183d0`（RC2） |
| 数据面协议 | **`org.apache.iotdb.consensus.iot.IoTConsensusV2`**（`show variables` 实测确认） |
| 集群 | 3 CN（26/27/28）+ 5 DN（2~6），Schema 3 副本 / Data 2 副本 |
| 用例 | 160 条（141 基础 + 19 补充） |
| 结果目录 | 见本目录 `a1.tsv`（普通）/ `a2.tsv`（三权分立） |

## 一、结果总览（协议 × 模式 四方对比）

| 协议 | 模式 | 用例 | PASS | FAIL | SKIP |
| --- | --- | ---: | ---: | ---: | ---: |
| IoTConsensus | 普通模式 | 160 | **150** | **0** | 10 |
| IoTConsensus | 三权分立 | 160 | **151** | **0** | 9 |
| IoTConsensusV2 | 普通模式 | 160 | **150** | **0** | 10 |
| IoTConsensusV2 | 三权分立 | 160 | **151** | **0** | 9 |

**逐条对比：两种协议在同一模式下完全没有判决差异**（`a3.md` 差异项为空）。
V2 下唯一差异仍是 LB-157（普通模式 SKIP / 三权分立 PASS，属设计内）。

## 二、协议切换方法（已验证）

1. CN 与 DN **双方** conf/iotdb-system.properties 写入：
   `data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensusV2`
   （只写 DN 不生效——`show variables` 读的是 CN 侧配置）
2. **必须清数据重建**（协议在建 DataRegion 时确定）
3. 同时把 `enable_separation_of_powers=false` 写回，避免三权分立状态残留
4. 校验：`show variables` → `DataRegionConsensusProtocolClass = ...IoTConsensusV2`

## 三、SKIP 明细（9 条，与 IoTConsensus 一致）

| 用例 | 原因 |
| --- | --- |
| LB-109 / LB-122 | 可写视图源为树模型，不做 LBAC 保护（已确认） |
| LB-143 | TAG / TIME 列是否允许 SECURED WITH（待需求确认） |
| LB-154 | 同一策略 READ/WRITE 能否授不同标签（待需求确认） |
| LB-158 / LB-159 / LB-160 | 导出 / pipe / LOAD 是否在 LBAC 检查范围（待需求确认） |
| LB-144 / LB-146 | 表模型不支持 RENAME / CTAS / LIKE（700） |
| LB-157 | 仅三权分立执行 |

## 四、日志检查

| 协议 | 模式 | 总行 | ERROR | WARN |
| --- | --- | ---: | ---: | ---: |
| IoTConsensus | 普通 | 399 | 2 | 397 |
| IoTConsensus | 三权分立 | 406 | 4 | 402 |
| IoTConsensusV2 | 普通 | 820 | 29 | 791 |
| IoTConsensusV2 | 三权分立 | 862 | 25 | 837 |

V2 的 ERROR/WARN 明显多于 IoTConsensus，但归类后均为**协议内部管道 + HA 重启**噪音：

| 类别 | 典型内容 | 是否 LBAC 相关 |
| --- | --- | --- |
| ConsensusPipe（V2 特有） | `[ConsensusPipeGuard]`、`PipePushMetaRPCHandler: Failed to PIPE_PUSH_ALL`、`PIPE_PUSH_ALL_META Timeout`、`PipeHeartbeatRPCHandler: Failed to PIPE_HEARTBEAT` | 否（V2 用内部 consensus pipe 同步 region，属协议自检/重试） |
| 选主/缓存 | `Timeout during CHANGE_REGION_LEADER`、`[LeaderBalancer] Failed to change the leader`、`Failed to INVALIDATE_LAST_CACHE`、`Failed to FLUSH` | 否（落在 HA 用例节点重启窗口） |
| Ratis/压缩 | `GrpcLogAppender is interrupted`、`CompactionWorker interruption` | 否（节点重启） |
| 配置加载 | `IoTDBDescriptor: Couldn't load the configuration` / `Cannot find IOTDB_HOME` | 否（三权分立开启瞬间进程重启） |

**结论：V2 下无 LBAC 相关 ERROR/WARN；增量日志全部来自 consensus pipe 与 HA 重启。**

## 五、结论

1. LBAC 功能在 **IoTConsensusV2** 下与 IoTConsensus **行为完全一致**：160 条用例逐条判决相同（150/151 PASS，0 FAIL）。
2. 三权分立模式下同样一致（151 PASS / 0 FAIL / 9 SKIP）。
3. V2 的额外日志（consensus pipe 心跳/推送重试）不影响 LBAC 判定，但日志量约为 IoTConsensus 的 2 倍，若后续做日志基线需把 `[ConsensusPipeGuard]`、`PIPE_PUSH_*`、`PIPE_HEARTBEAT` 纳入噪声白名单。
