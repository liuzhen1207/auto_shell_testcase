# 结果与日志的保留策略（2026-10-21 定）

> 用户口径：**"运行完测试后，如果没必要保留某些日志，就删除；如果用例 fail 需要提单，就需要打包 CN/DN 日志"**。
> 落地脚本：`tools/prune_results.sh`（默认 dry-run，`--apply` 才删）。

## 1. 一律保留（体积很小）

| 路径 | 说明 |
| --- | --- |
| `results/test_result.csv` | 逐次运行的历史结果（每次 --set/--only 一行一条），后续所有矩阵/对照都靠它 |
| `results/final_results.csv` | `tools/build_matrix_report.py` 生成的权威表 |
| `docs/MATRIX_*.md` | 双协议矩阵报告 |
| `results/artifact_*` 中**"还要提单 / 还要研发口径"的** | 见 §2 清单 |

## 2. 需要保留 artifact 的用例（fail 要提单或结论未定）

脚本里是这张正则：`KEEP_PAT`

```
co06 | dt_tree | co_object_ttl | co_param_gate | co_level_search | co_fast_fake
wal_memtable_snapshot | wal_param_invalid | wal_object | wal_recovery_metadata
wal_compress | wal_dir_config | wal_disk_readonly | wal_recovery_dn_down | wal_metrics
cr_table_time_only | cr_load_lastcache
```

对应关系：

| 用例 | 为什么留 |
| --- | --- |
| CO-06 / DT-09 | 已提缺陷 **TDB-836 / TDB-837**，日志是单子证据（本地 `tdb678_verify/artifacts/evidence/` 也有一份） |
| DT-02 / DT-04 | **PLM 观察项 docs/1063**（V2 syncLag 语义）的证据 |
| CO-15 / CO-36 / CO-38 / CO-41 | 结论还在迭代（第三/四轮复跑），现场日志要能回看 |
| W-16 / W-21 | **可能要提单**（凭空多出的点数、静默接受非法取值） |
| W-19 / W-20 / W-08 / W-24 / W-25 / W-06 / W-18 | 用例侧待修/待定性，需要现场证据复核 |
| W-11 / W-12 | 指纹 15/16、V2 新增失败，结论未定 |
| W-07 / W-23 | 复跑对照用 |
| CR-03 / CR-13 | 结论未定（CR-13 的 BLOB 语义要研发口径） |

## 3. 一律可以删

| 内容 | 说明 |
| --- | --- |
| `results/*.out` 中**非本轮**的（早于本轮开跑时间） | 结论已进 CSV/文档；`test_result.csv` 里仍保留每次的 result/fail/耗时/message 摘要 |
| `results/artifact_*` 里**不在 §2 清单**的 | 那些用例已 PASS 或已定性为用例侧并修好 |
| `*.tar` / `*.tgz` 中间包 | 除非是已打包好的提单证据 |

## 4. 收尾顺序（推荐）

```bash
# 1) 双协议矩阵先出（它只读 CSV/.out，删了 .out 之后历史轨迹会变少）
python3 tools/build_matrix_report.py --skill . --build ebaf9da --out docs/MATRIX_RC8.md

# 2) 需要提单的用例：先打包 CN/DN 日志（artifact 里已含三节点 logs.tgz）
tar -czf ~/evidence_$(date +%Y%m%d).tgz results/artifact_<case>_*

# 3) dry-run 看要删什么，确认后 --apply
bash tools/prune_results.sh
bash tools/prune_results.sh --apply
#    若要"连保留清单也压成 tgz 再删目录"（最省空间）：
bash tools/prune_results.sh --apply --no-keep-artifacts
```

## 5. 已知大头（不是这条链的，别乱删）

| 路径 | 说明 |
| --- | --- |
| `/data/monitor/prometheus` | 监控 TSDB（查 syncLag 用的那个），无保留期会一直涨；要空间从这里下手最有效 |
| `/data/iotdb/autotest/testcase/remove_cn_leader_results` | 别人的历史结果目录 |
| `/data/iotdb/testdb` | 各版本安装/解包目录 |
| `/data/iotdb/rc6_*.zip` | 旧版本安装包 |
