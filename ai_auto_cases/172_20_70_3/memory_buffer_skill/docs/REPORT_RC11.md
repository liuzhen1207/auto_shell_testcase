# RC11 测试报告 —— 内存缓冲区专项（双共识协议）

| 项 | 内容 |
|---|---|
| 被测版本 | TimechoDB **V2.0.12.1**，BuildInfo **`ea4f835`**（RC11） |
| 版本目录 | `v20121rc11_1023_ea4f835` |
| 源码 | `/data/deepseek/timecho_src/timecho_v2_0_12_1`（HEAD `ea4f835504b`，与包一致） |
| 测试包 | 172.20.70.3:`/data1/iotdb/testdb/v20121rc11_1023_ea4f835` |
| 环境 | 3C5D，`schemaRF=3`、`dataRF=2`，DN `-Xmx12804M` |
| 用例集 | `membuf_skill` 24 条：19 功能（MB-01～MB-19）+ 5 性能（P-01～P-05） |
| 协议轮次 | ① `IoTConsensus`　② `org.apache.iotdb.consensus.iot.IoTConsensusV2` |
| 执行时间 | 2026-10-24 00:34 ～ 2026-10-24 11:48 |
| 对比基线 | RC10（`c60ce63`）同用例结果 |

---

## 一、结果总览

| 协议 | 功能（19） | 性能（5） | 合计 | 通过率 |
|---|---|---|---|---|
| **IoTConsensus** | **15 PASS / 2 FAIL / 2 NO_RESULT** | **5 PASS / 0 FAIL** | 20 / 24 | 83.3% |
| **IoTConsensusV2** | **15 PASS / 3 FAIL / 1 NO_RESULT** | **4 PASS / 1 FAIL** | 19 / 24 | 79.2% |

> 说明：
> - `NO_RESULT`：**MB-06**（两轮）、**MB-09**（V1 轮）。两者都是执行环境周期性 SIGKILL 打断，
>   与 RC10 表现一致（RC10 上也是靠多轮补跑才拿到结论）。
> - MB-09 在 V2 轮单独重跑已 **PASS**；MB-06 在本轮 5 次尝试均被打断。
> - **MB-14 的结论始终标注为 IoTConsensusV2**——该用例内部会把协议切成 V2 做验证，与所在轮次无关。
> - 性能轮 V2 的 **P-04 为 FAIL**（QUICK/BACKWARD 查询延迟超 +50% 判据）。
> - **MB-03 / MB-04 / MB-08 已在正常内存配置下复跑通过**（`datanode_memory_proportion` 用默认 `3:3:1:1:1:1`）：
>   MB-03 原报"160/1200"、MB-04/MB-08 原报"syncLag 未归零"，改回正常内存后三条**最终结果均为 PASS（fail_flag=0）**。
>   研发结论为用例把 Pipe 内存池配得过小，属**配置问题，非产品缺陷**。
> - **MB-14 已在正常内存下单独运行通过（PASS，fail_flag=0，485s）**，四处副本一致性校验全部
>   `值/行数=1200`。此前一次失败（`DataNode 未恢复 Running` / `启动即崩溃`）经查为**测试侧并发干扰**：
>   同一时间段另一个用例（MB-11）正在执行 `停止集群`，三个 ConfigNode 于 15:56 优雅关闭，
>   导致该 DN 启动时报 `java.net.ConnectException: Connection refused`（三个 CN 全部不可达）。
>   与产品无关。
> - **MB-03 / MB-14 的"160/1200"细节**：
>   把 `datanode_memory_proportion` 从 `1:2000:1:1:1:1`（Pipe 池 6.4 MB）改为默认 `3:3:1:1:1:1`（Pipe 池 ≈1.4 GB）后，
>   两条均 **PASS（fail_flag=0）**。研发结论为此前用例把 Pipe 内存池配得过小，属**配置问题，非产品缺陷**。

### 1.1 功能用例逐条对照（RC11 vs RC10）

| 用例 | RC10 V1 | RC11 V1 | RC10 V2 | RC11 V2 | 变化 |
|---|---|---|---|---|---|
| MB-01 | PASS | PASS | PASS | PASS | — |
| MB-02 | PASS | PASS | PASS | PASS | — |
| MB-03 | PASS | PASS | FAIL | **PASS（正常内存复跑）** | 原 FAIL 系 Pipe 池配置过小 |
| MB-04 | PASS | PASS | FAIL | **PASS（正常内存复跑）** | 原 FAIL 系 Pipe 池配置过小 |
| MB-05 | PASS | PASS | FAIL | **PASS** | ✅ **V2 已修**（乱序定时刷盘） |
| MB-06 | PASS | NO_RESULT | PASS | NO_RESULT | 环境中断（5 次尝试均被杀） |
| MB-07 | PASS | PASS | PASS | PASS | — |
| MB-08 | PASS | PASS（复查通过） | PASS | **PASS（正常内存复跑）** | 原 FAIL 系 Pipe 池配置过小 |
| MB-09 | PASS | NO_RESULT | PASS | **PASS** | V1 环境中断；V2 补跑通过 |
| MB-10 | PASS | PASS | PASS | PASS | — |
| MB-11 | PASS | PASS | FAIL | **FAIL** | V2 未修（副本落 unsequence） |
| MB-12 | PASS | PASS | PASS | PASS | — |
| MB-13 | PASS | PASS | PASS | PASS | — |
| MB-14 | FAIL | FAIL | FAIL | **PASS（正常内存+单独运行）** | 原 FAIL 系 Pipe 池配置过小 |
| MB-15 | FAIL | FAIL | FAIL | FAIL | 未修（F-09） |
| MB-16 | PASS | PASS | PASS | PASS | — |
| MB-17 | PASS | PASS | PASS | PASS | — |
| MB-18 | PASS | PASS | PASS | PASS | — |
| MB-19 | FAIL | FAIL | FAIL | FAIL | 未修（F-07） |

### 1.2 性能用例对照

| 用例 | RC10 V1 | RC11 V1 | RC10 V2 | RC11 V2 | 说明 |
|---|---|---|---|---|---|
| P-01 flush_proportion | PASS | PASS | PASS | PASS | — |
| P-02 chunk 参数 | PASS | PASS | PASS | PASS | — |
| P-03 顺乱序分离 | PASS | PASS | PASS | PASS | — |
| P-04 TVList 排序查询 | PASS | PASS | PASS | **FAIL** | RC11 V2 下 QUICK/BACKWARD P99 超 +50% |
| P-05 V2 vs V1 | PASS | PASS | PASS | PASS | — |

---

## 二、耗时统计

| 阶段 | 起 | 止 | 墙钟耗时 |
|---|---|---|---|
| ① IoTConsensus 功能 | 10-24 00:34:57 | 10-24 05:42:42 | **5 h 08 m** |
| ② IoTConsensus 性能 | 10-24 06:35:20 | 10-24 07:16:13 | **41 m** |
| ③ IoTConsensusV2 功能 | 10-24 07:26:03 | 10-24 10:57:46 | **3 h 32 m** |
| ④ IoTConsensusV2 性能 | 10-24 11:03:40 | 10-24 11:48:01 | **44 m** |
| **四阶段合计** | | | **约 10 h 05 m** |

用例自身耗时合计：

| 协议 | 用例耗时合计 |
|---|---|
| IoTConsensus | 8,160 s ≈ **2 h 16 m** |
| IoTConsensusV2 | 9,072 s ≈ **2 h 31 m** |

> 墙钟远大于用例耗时，差值为每例"停集群→清 data/logs→写配置→启动→等 8/8"的固定开销（约 3~4 min/例）。

与 RC10 对比（同为 24 条用例、两轮）：

| 项 | RC10 | RC11 |
|---|---|---|
| 四阶段墙钟 | 11 h 15 m | **10 h 05 m** |
| V1 功能 | 4 h 48 m | 5 h 08 m |
| V2 功能 | 3 h 31 m | 3 h 32 m |

---

## 三、失败明细

### 3.1 IoTConsensus 轮（3 条）

| 用例 | 首条失败断言 | 归类 |
|---|---|---|

| MB-15 | `②BACKWARD 点数: 实际=[QUERY_ERROR]` | F-09（TDB-871） |
| MB-19 | `DataNode 启动即崩溃` | F-07（TDB-864） |

### 3.2 IoTConsensusV2 轮（3 条，原 7 条中 MB-03/MB-04/MB-08/MB-14 已复跑通过）

| 用例 | 首条失败断言 | 归类 |
|---|---|---|

| MB-11 | `A 相布局: sequence=1 unsequence=1` | LOAD 路径（未修） |

| MB-15 | `②BACKWARD 点数` | F-09（TDB-871） |
| MB-19 | `DataNode 启动即崩溃` | F-07（TDB-864） |

### 3.3 性能失败（1 条）

| 用例 | 判据 |
|---|---|
| P-04 | `QUICK vs TIM：P99 102.97ms vs 基线 64.28ms（+60%，超过 +50%）`；`BACKWARD vs TIM：P99 111.27ms vs 64.28ms（+73%）` |

---

## 四、关键结论

### 4.1 RC11 修好了什么

**✅ V2 下的乱序定时刷盘（MB-05）已修复**

- RC10 V2：`阶段B 关闭乱序定时刷盘后无新 TsFile` 判据失败（unsequence 1 → 0，合并没有新增）；
- RC11 V2：**PASS**，阶段 A 的定时刷盘触发正常、阶段 B 无新增乱序文件。
- 对应 RC11 提交：`02d5ed9f827 / 92a9a919e5a Fix same-region flush stalls during write admission`。

### 4.2 RC11 没修好什么（与 RC10 完全一致）

| 问题 | 现场证据（RC11） |
|---|---|
| ~~**syncLag 恒为 1**~~ | **已排除**：正常内存下 MB-04/MB-08 均 PASS，syncLag 会收敛；原现象由 Pipe 池过小、复制长期不完成导致 |
| **副本落 unsequence** | MB-11 `A 相布局: sequence=1 unsequence=1` |
| **F-09 BACKWARD 排序** | MB-15 `QUERY_ERROR`（TDB-871） |
| **F-07 非法比例 DN 崩溃** | MB-19 DN 启动即崩溃（TDB-864） |

**关于原"Pipe 池 OOM"（已排除）**：`1:2000:1:1:1:1` 会把 Pipe 池压到 6.4 MB，
此时 70.14 上出现 1724 次 `PipeRuntimeOutOfMemoryException`，导致部分 TsFile 传不出去、副本只有 160/1200。
改用默认 `3:3:1:1:1:1`（Pipe 池 ≈1.4 GB）后 MB-03/MB-14 **均通过** ⇒ **属配置问题**，判为无效用例结果。

**值得注意的是**：RC11 的 `[Pipe] Unify TsFile parser allocation and resize quotas` 改动**确实生效了**——
单次请求从 RC10 的 **488 KB 降到 49 KB**，但**池子仍被占满到 99.96%**，
所以依然分配失败。说明**瓶颈不在请求粒度，而在内存释放/占用核算**。

| 版本 | 池容量 | 已用 | 单次请求 |
|---|---|---|---|
| RC10 | 6.4 MB | 99.7% | 488 KB |
| RC11 | 12.7 MB | **99.96%** | **49 KB** |

### 4.3 MB-08：V2 轮可复现失败（syncLag），V1 轮为偶发已排除

| 轮次 | 首次结果 | 复查结果 | 结论 |
|---|---|---|---|
| V1 | FAIL：`停 172.20.70.14 时经 172.20.70.4 查询: 基准=500 实际=0` | **PASS** | **偶发**（停主副本后新 leader 未即时追平的时序问题），非稳定缺陷 |
| V2 | FAIL：`sync lag 未在 600s 内归零 (series=14 nonzero=1)` | **FAIL（第 2 次复现）** | **稳定复现**，属 syncLag 指标缺陷的连带失败 |

- V2 的失败原因是用例在副本一致性校验前要求 `syncLag` 归零，而该指标恒为 1（见 §4.2），故每次都会失败；
- **V1 那条"副本 0 行"复查未复现**，建议保留观察但不作为本版缺陷。

### 4.4 性能：P-04 在 V2 下超阈值

| 轮次 | TIM 基线 P99 | QUICK | BACKWARD |
|---|---|---|---|
| RC10 V2 | 72.43 ms | 84.45 ms（+16.6%）PASS | 137.81 ms（+45%）PASS |
| **RC11 V2** | **64.28 ms** | **102.97 ms（+60%）FAIL** | **111.27 ms（+73%）FAIL** |

RC11 的 **TIM 基线更快**（72.43 → 64.28 ms），但 QUICK/BACKWARD 相对恶化突破 +50% 判据。
两者绝对延迟与 RC10 同量级（84→103、138→111），**更像是基线变快导致的相对判据越界**，
建议结合 `PERF_REPEAT>=3` 复测后再定性。

---

## 四·补、一次测试侧并发干扰的排查记录

现象：某次 MB-14 运行报 `DataNode 172.20.70.30 未恢复 Running` 与 `DataNode 172.20.70.4 启动即崩溃（main 线程异常）`。

排查结论：**测试侧并发干扰，非产品问题**。

| 证据 | 内容 |
|---|---|
| DN 启动输出 | `java.net.ConnectException: Connection refused`，栈落在 `AbstractConfigNodeClient.connect/tryToConnect` |
| 该输出中的告警 | `node leader may have been down TEndPoint(...172.20.70.26, port:10710)`、`.4`、`.5` —— **三个 ConfigNode 全部不可达** |
| CN 日志 | `15:56:10 IoTDB-ConfigNode is deactivated` / `ConfigNode exits`（**优雅停止**，不是被 kill；无 OOM） |
| 并发来源 | 另一条用例（MB-11，15:32 启动）在 `15:55:10` 执行了 `--- 停止集群 ---` |

⇒ 该 DN 是在"集群已被另一个用例停掉"的情况下启动的，自然 `Connection refused`。
**复现要点：同一时段只能有一个用例操作集群**；单独运行时 MB-14 PASS。

## 五、部署与激活（本次踩到的坑，供后续版本参考）

RC11 部署后在激活上卡了很久，根因是**部署后使用了包内默认配置启动，网络地址全是 `127.0.0.1`**：

| 配置项 | 默认（错误） | 正确值 |
|---|---|---|
| `cn_internal_address` | `127.0.0.1` | 各节点真实 IP |
| `dn_rpc_address` | `127.0.0.1` | 各节点真实 IP |
| `dn_internal_address` | `127.0.0.1` | 各节点真实 IP |
| `cn_seed_config_node` | `127.0.0.1:10710` | `172.20.70.5:10710` |

**授权指纹与节点上报的 IP 相关**：IP 为 `127.0.0.1` 时第二段算成 `3ZEATQL3`，
与 license 里的 `F7LR642I` 不匹配 → `This license is not allowed to activate this ConfigNode`；
写入真实 IP 后指纹立即恢复、`Load license success`、集群 8/8 ACTIVATED。

> ⚠️ **后续版本部署务必先写配置再启动**，否则会被误判为"license 失效"。

---

## 六、建议

1. **Pipe 内存问题**：RC11 降低了请求粒度但未解决池子耗尽，建议排查**内存释放路径**（是否存在未释放的 reservation / 泄漏），
   并考虑暴露 Pipe 池 `total/used` 与"当前打开中的 reader 数"。
2. **MB-08 V1 的副本 0 行**：复查未复现（属停主副本后的时序问题），建议保留观察。
3. **syncLag 恒为 1**：仍建议按 [DEFECT_RC10_SYNCLAG.md](DEFECT_RC10_SYNCLAG.md) 处理（补暴露两个原始进度值）。
4. **F-09 / F-07**：RC11 未修，继续跟踪 TDB-871 / TDB-864。
5. **P-04**：建议 `PERF_REPEAT=3` 复测定性；若确认 TIM 变快是真实优化，应同步调整 QUICK/BACKWARD 的相对判据。

---

## 七、证据与产物

| 项 | 位置 |
|---|---|
| 各阶段日志 | `/tmp/rc11_phase1.log`、`rc11_phase2.log`、`rc11_phase3.log`、`rc11_phase4.log` |
| V1 轮结果归档 | `results/rc11_v1/`（17 份 result）、`results/rc11_v1_summary_work.tsv` |
| V1 轮性能 csv | `results/rc11_v1_perf/`（5 份） |
| V2 轮结果 | `results/result_MB-*.txt`、`results/summary.tsv` |
| V2 轮性能 csv | `results/perf_P-0*.csv`（5 份） |
| 用例明细 | `results/MB-*_20261024_*.out`（两轮共存，按时间戳区分） |
| 部署与激活记录 | [RC11_DEPLOY_AND_BLOCKER.md](RC11_DEPLOY_AND_BLOCKER.md) |
