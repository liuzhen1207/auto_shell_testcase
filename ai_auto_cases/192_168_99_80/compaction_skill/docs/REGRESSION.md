# 发版回归怎么跑（冻结清单 + 分层策略）

> 用户约定（2026-10-15）：以后说 **"回归测试合并"** ⇒ 就跑 `--set regression` 这一份**冻结清单**。
> 本文是那份清单的定义、命令、耗时与准入策略。

## 一、冻结清单 = 52 条

| 批次 | 编号 | 条数 | 主题 |
| --- | --- | --- | --- |
| 第一批 | CO-01 ~ CO-17 | 17 | 冒烟/删除/元数据/类型编码/对齐/参数静态/热加载/性能/缩容/TTL/参数组合①②③边界 |
| 第二批 | CO-18 ~ CO-32 | 15 | 逐参数最基础场景 + 基础形态与生命周期（含自动修复开关） |
| 数据类型专项 | DT-01 ~ DT-09 | 9 | 按《修改数据类型手册更新内容》：树/表改类型、并发、×合并、视图改列类型、磁盘 readonly、节点下线 |
| RC7 修复链路/压力 | CO-33、CO-34 | 2 | 未排序 TsFile 真实修复链路（load + `START REPAIR DATA`，覆盖官方 4 类错误中的 3 类）；千级 TsFile 级联压力 |
| 官方文档补齐 | CO-35 ~ CO-42 | 8 | 官方《软件测试文档》+ 设计文档覆盖度核对后的高价值缺口（拆分公式/FastCompaction/分组/逐层选择/优先级/恢复分支/OBJECT×TTL/fast 对比） |
| 官方缺陷史补强 | **CO-43** | 1 | **同名序列重建 + 对齐属性翻转后的合并**（官方 MG-P18/MG-P19，缺陷 **IOTDB-5686**：官方首测"只有 80 个点、数据不一致"，两轮复测才通过；含重启后复验） |

清单文件：`cases/regression.txt`（一行一个 ID；**这是唯一权威定义**）。
`--set all` 会跑 cases.tsv 里的所有用例（含将来的试验性用例），**不等价于回归清单**。

## 二、命令

```bash
cd /data/iotdb/autotest/compaction_skill

# ① 发版回归（51 条，单协议）：把 <版本目录名> 换成待测版本，例如 v20121rc7_1014_7c61428
bash tools/run_all.sh --set regression --ver <版本目录名> --consensus IoTConsensus

# ② hotfix 快速门禁（8 条，约 1.5~1.7h）：合并主链路 + 改类型主链路 + 修复链路
bash tools/run_all.sh --set quick --ver <版本目录名> --consensus IoTConsensus

# ③ 双协议（部分用例两种 data region 协议都要看）
bash tools/run_all.sh --set regression --ver <版本目录名> --consensus IoTConsensus
bash tools/run_all.sh --set regression --ver <版本目录名> --consensus IoTConsensusV2

# ④ 定点复跑（例如只复跑失败项）
bash tools/run_all.sh --set regression --only CO-33,DT-07 --ver <版本目录名>
```

- **版本切换不用手工改配置**：`--ver` 会覆盖 `V_TESTDB/BUILD_TAG`，`cmp_align_version()` 在每条用例的
  `cmp_cluster_prepare` 第一步把框架 `conf/test.conf` 的 `v_testdb/v_commit` 对齐（不一致时备份 `.bak_<ts>`），
  避免"框架起了 A 版本、用例却去看 B 版本目录"的错位。
- 每条用例自带"集群准备（停→清→写参数→启）"，**串行执行**；`run_all.sh` 有 `flock` 非阻塞锁，**禁止并发跑两份 run_all**。

## 三、耗时（RC6 实测外推，单协议）

| 范围 | 实测 | 说明 |
| --- | --- | --- |
| CO-01~17 | 10205 s = **2.83 h** | RC6 实跑 |
| CO-18~32 | 7954 s = **2.21 h** | RC6 实跑 |
| DT-01~09 | 4652 s = **1.29 h** | RC6 实跑 |
| 41 条合计 | 22811 s = **6.34 h** | `results/final_results.csv` |
| CO-33 / CO-34 | 约 20~30 min / 40~60 min | 首跑待实测 |
| CO-35~43（9 条） | 约 15~25 min 每条 ⇒ **2.5~3.5 h** | CO-43 含**整集群重启**，偏上限 |
| **52 条合计** | 估 **9.5~11 h**（单协议） | 双协议约 ×1.8 |

**建议**：发版回归排一整个工作日的窗口（或夜里跑）；hotfix 只看 `--set quick`；
`--only` 可用于失败项定点复跑。

## 四、结果与证据位置

| 产物 | 内容 |
| --- | --- |
| `results/test_result.csv` | 每条用例一行：build/consensus/用例/结果/耗时/failFlag/artifact/message（累积） |
| `results/final_results.csv` | 汇总结论（同一用例取最后一轮） |
| `results/SUITE_<set>_<runid>.out` | 套件级汇总（含"第一个失败"上下文） |
| `results/<ID>_<runid>.out` | 单用例完整输出（含所有判据与实测值） |
| `results/artifact_<case>_<runid>/` | 失败时自动打包的 CN/DN 日志 |

## 五、新增用例的准入策略（保持"回归"含义稳定）

1. 新用例先写进 `cases/cases.tsv`，归入 `--set official`（或专门的集合），**不直接进回归清单**；
2. 在**某个版本上实跑通过**（`fail_flag=0`）之后，才把 ID 追加进 `cases/regression.txt`；
3. 产品缺陷类门禁（如 DT-07 → TDB-678）**保留在清单内**：它们在修复前 FAIL 是预期的，
   修复后应转 PASS —— 这正回归要盯的。

## 六、暂不补充的场景（如实记录，不硬凑）

`docs/OFFICIAL_COVERAGE.md` §6 已逐条列出：官方测试文档 **28 条** + 设计规则 **7 组**在本环境
**不可构造**（亿级序列 / TB 级备份 / 跨版本对比 / 5 天~7×24 长稳 / 刻意 OOM / 历史缺陷产物
（IOTDB-5210/5165/5671/5706 等）/ 1002 个文件反复改 heap 二分 等）。

§4.3 另有 **8 条备选**（本轮未入选前 8）。其中优先级最高、**且本轮已实现**的是：
**同名序列重建 + 对齐属性翻转**（MG-01-1/2/3、MG-P18/P19/P20，对应官方缺陷史 IOTDB-5686，两轮复测才通过）
⇒ 见 **CO-43**（`cases/common/co_samename_aligned_flip.sh`）；其余 7 条因"构造确定性低 / 需长窗口压测 /
负向门禁风险高 / 待确认版本差异"而有意排除。
若某版本改动涉及对应模块，可临时把相应备选实现出来，作为该版本的定向验证。
