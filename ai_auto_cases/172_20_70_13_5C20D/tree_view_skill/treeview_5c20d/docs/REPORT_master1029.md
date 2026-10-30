# 树转表视图回归报告 —— 最新 master（BuildInfo `2bbab08`）

| 项 | 值 |
|---|---|
| 源码 | `/data/deepseek/timecho_src/master/timechodb`，HEAD `2bbab0892b` |
| 构建 | `timechodb-2.0.11-SNAPSHOT-bin.zip`（2026-10-29 16:30 构建） |
| 部署 | 5 ConfigNode + 20 DataNode（172.20.70.100–119），SR3 / DR3 |

## 一、两轮总览

| 协议 | 用例数 | PASS | FAIL | 开始 | 结束 | 总耗时 |
|---|---|---|---|---|---|---|
| **IoTConsensus** | 46 | 36 | 10 | 2026-10-29 17:20:38 | 2026-10-30 05:06:19 | 42341 s（11.8 h） |
| **IoTConsensusV2** | 46 | 40 | 6 | 2026-10-30 05:13:20 | 2026-10-30 16:58:34 | 42314 s（11.8 h） |

## 二、逐条结果与用时

| 用例 | IoTConsensus | 总用时 | 其中准备 | IoTConsensusV2 | 总用时 | 其中准备 | 失败/归属 |
|---|---|---|---|---|---|---|---|
| TV-BASE-01 | PASS | 997s | 693s | PASS | 990s | 697s |  |
| TV-BASE-02 | PASS | 780s | 689s | PASS | 775s | 692s |  |
| TV-BASE-03 | PASS | 779s | 692s | PASS | 776s | 692s |  |
| TV-BASE-04 | PASS | 996s | 690s | PASS | 975s | 685s |  |
| TV-BASE-05 | PASS | 790s | 704s | PASS | 775s | 694s |  |
| TV-BASE-06 | PASS | 1003s | 697s | PASS | 984s | 688s |  |
| TV-BASE-07 | FAIL | 790s | 700s | FAIL | 774s | 687s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-894 |
| TV-BASE-08 | PASS | 782s | 698s | PASS | 776s | 695s |  |
| TV-BASE-09 | PASS | 774s | 688s | PASS | 783s | 696s |  |
| TV-BASE-10 | PASS | 773s | 689s | PASS | 778s | 693s |  |
| TV-BASE-11 | PASS | 985s | 693s | PASS | 989s | 699s |  |
| TV-BASE-12 | PASS | 783s | 700s | PASS | 785s | 703s |  |
| TV-BASE-13 | PASS | 780s | 685s | PASS | 785s | 692s |  |
| TV-BASE-14 | PASS | 798s | 700s | PASS | 787s | 691s |  |
| TV-BASE-15 | PASS | 772s | 681s | PASS | 778s | 695s |  |
| TV-HA-01 | PASS | 812s | 692s | PASS | 814s | 699s |  |
| TV-HA-02 | PASS | 815s | 695s | PASS | 814s | 696s |  |
| TV-HA-03 | FAIL | 1678s | 695s | PASS | 1670s | 697s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → 测试侧噪声(license) |
| TV-LEAK-01 | FAIL | 868s | 707s | PASS | 859s | 701s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-REF-01 | PASS | 782s | 690s | PASS | 791s | 702s |  |
| TV-REF-02 | PASS | 779s | 688s | PASS | 798s | 701s |  |
| TV-REF-03 | PASS | 981s | 693s | PASS | 994s | 700s |  |
| TV-REF-04 | PASS | 783s | 702s | PASS | 786s | 700s |  |
| TV-REF-05 | PASS | 981s | 693s | PASS | 998s | 701s |  |
| TV-REF-06 | PASS | 773s | 690s | PASS | 778s | 695s |  |
| TV-REPRO-D1 | FAIL | 1040s | 693s | PASS | 1038s | 692s | IoTConsensus: D1 缺陷面：模板激活不应在 DN 日志留下 ViewColumnAutoSyn → TDB-890 |
| TV-REPRO-D2 | PASS | 787s | 687s | PASS | 807s | 702s |  |
| TV-REPRO-D3 | FAIL | 787s | 690s | FAIL | 794s | 697s | IoTConsensus: D3 缺陷面：该**预期失败**不应在 CN 日志留下 ERROR → TDB-894 |
| TV-REPRO-D4 | PASS | 831s | 700s | PASS | 827s | 694s |  |
| TV-REPRO-D5 | FAIL | 3782s | 702s | PASS | 3772s | 715s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → 测试侧噪声(license) |
| TV-SYNC-01 | PASS | 807s | 705s | PASS | 799s | 695s |  |
| TV-SYNC-02 | PASS | 794s | 693s | PASS | 784s | 684s |  |
| TV-SYNC-03 | FAIL | 790s | 692s | FAIL | 781s | 691s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-SYNC-04 | FAIL | 1006s | 691s | FAIL | 1002s | 693s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-SYNC-05 | PASS | 999s | 695s | FAIL | 1010s | 706s | IoTConsensusV2: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-SYNC-06 | PASS | 793s | 705s | PASS | 780s | 692s |  |
| TV-SYNC-07 | PASS | 775s | 692s | PASS | 770s | 691s |  |
| TV-SYNC-08 | PASS | 800s | 698s | PASS | 793s | 683s |  |
| TV-SYNC-09 | PASS | 995s | 686s | PASS | 995s | 685s |  |
| TV-SYNC-10 | PASS | 783s | 699s | PASS | 782s | 697s |  |
| TV-SYNC-11 | FAIL | 789s | 682s | PASS | 798s | 698s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-SYNC-12 | PASS | 811s | 693s | PASS | 816s | 697s |  |
| TV-SYNC-13 | FAIL | 795s | 689s | FAIL | 801s | 694s | IoTConsensus: 收尾③ CN/DN 日志无 ERROR/WARN 异常 → TDB-890 |
| TV-SYNC-14 | PASS | 799s | 698s | PASS | 791s | 694s |  |
| TV-SYNC-15 | PASS | 765s | 682s | PASS | 780s | 696s |  |
| TV-SYNC-16 | PASS | 779s | 690s | PASS | 782s | 699s |  |

## 三、时长统计

| 协议 | 用例总耗时(会话) | 平均/条 | 最长用例 | 最短用例 |
|---|---|---|---|---|
| IoTConsensus | 42341s（11.8 h） | 920s | TV-REPRO-D5 3782s | TV-SYNC-15 765s |
| IoTConsensusV2 | 42314s（11.8 h） | 919s | TV-REPRO-D5 3772s | TV-SYNC-07 770s |


- **IoTConsensus**：集群准备合计 31906s（8.9 h，占 75%）；用例本体合计 10435s（2.9 h，占 25%）
- **IoTConsensusV2**：集群准备合计 31986s（8.9 h，占 76%）；用例本体合计 10328s（2.9 h，占 24%）

## 四、失败归属

**IoTConsensus**：10 条 FAIL
- `TV-BASE-07`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-894**
- `TV-HA-03`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **测试侧噪声(license)**
- `TV-LEAK-01`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-REPRO-D1`：D1 缺陷面：模板激活不应在 DN 日志留下 ViewColumnAutoSyncTrigger ERROR → **TDB-890**
- `TV-REPRO-D3`：D3 缺陷面：该**预期失败**不应在 CN 日志留下 ERROR → **TDB-894**
- `TV-REPRO-D5`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **测试侧噪声(license)**
- `TV-SYNC-03`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-04`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-11`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-13`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**

**IoTConsensusV2**：6 条 FAIL
- `TV-BASE-07`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-894**
- `TV-REPRO-D3`：D3 缺陷面：该**预期失败**不应在 CN 日志留下 ERROR → **TDB-894**
- `TV-SYNC-03`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-04`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-05`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**
- `TV-SYNC-13`：收尾③ CN/DN 日志无 ERROR/WARN 异常 → **TDB-890**

## 五、协议对比结论

- 两轮**都跑过**的用例：46 条；其中 **40 条结论完全相同**（同为 PASS 或同为 FAIL）
- 结论不同的用例（6 条，多为 TDB-890 间歇触发）：
  - `TV-SYNC-05`：V1=PASS，V2=FAIL
  - `TV-HA-03`：V1=FAIL，V2=PASS
  - `TV-LEAK-01`：V1=FAIL，V2=PASS
  - `TV-REPRO-D5`：V1=FAIL，V2=PASS
  - `TV-SYNC-11`：V1=FAIL，V2=PASS
  - `TV-REPRO-D1`：V1=FAIL，V2=PASS
- 平均单条耗时：IoTConsensus **920s** vs IoTConsensusV2 **920s**（差异 -0.1%）

