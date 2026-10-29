# 合并专项：52 条用例 × 双协议 结果总表（自动生成）

> 由 `tools/build_matrix_report.py` 生成；数据源 `results/*.csv` + `results/*.out`；作废规则见 `results/INVALIDATED.tsv`。**请勿手工编辑**。

## 1. 总览

| 协议 | PASS | FAIL | MISSING |
| --- | --- | --- | --- |
| IoTConsensus | 50 | 2 | 0 |
| IoTConsensusV2 | 42 | 10 | 0 |

双协议一致性：**一致 44** / 分歧 8 / 缺 0（共 52 条用例）

其中**预期门禁失败**（已知缺陷的门禁，非新回归失败）：CO-06/IoTConsensusV2
## 2. 主表

| 用例 | 脚本 | V1（IoTConsensus） | V2（IoTConsensusV2） | 一致性 | 备注 |
| --- | --- | --- | --- | --- | --- |
| CO-01 | co_tree_inner_smoke.sh | PASS (355s) | PASS (349s) | 一致 |  |
| CO-02 | co_table_inner_smoke.sh | PASS (338s) | PASS (351s) | 一致 |  |
| CO-03 | co_unseq_inner.sh | PASS (369s) | PASS (429s) | 一致 |  |
| CO-04 | co_cross_space.sh | PASS (541s) | PASS (599s) | 一致 |  |
| CO-05 | co_delete_data.sh | PASS (542s) | PASS (685s) | 一致 |  |
| CO-06 | co_metadata.sh | PASS (746s) | FAIL (950s fail=2) **[预期门禁]** | **分歧** | V1=PASS V2=FAIL 预期门禁：TDB-836（IoTConsensusV2 下 pipe 进度索引未随 DataRegion 删除清理导致 DataNode NPE）——RC8 仍复现，FAIL 属预期 |
| CO-07 | co_data_types_encoding.sh | PASS (493s) | PASS (526s) | 一致 |  |
| CO-08 | co_aligned_null.sh | PASS (367s) | PASS (390s) | 一致 |  |
| CO-09 | co_conf_params.sh | PASS (676s) | PASS (682s) | 一致 |  |
| CO-10 | co_hot_reload.sh | PASS (463s) | PASS (474s) | 一致 |  |
| CO-11 | co_perf_baseline.sh | PASS (1659s) | PASS (1658s) | 一致 |  |
| CO-12 | co_remove_nodes.sh | PASS (656s) | PASS (657s) | 一致 |  |
| CO-13 | co_ttl_settle.sh | PASS (580s) | PASS (643s) | 一致 |  |
| CO-14 | co_ttl_table_settle.sh | PASS (523s) | PASS (588s) | 一致 |  |
| CO-15 | co_param_gate_matrix.sh | PASS (1682s) | FAIL (1782s fail=3) | **分歧** | V1=PASS V2=FAIL |
| CO-16 | co_param_selector.sh | PASS (914s) | PASS (954s) | 一致 |  |
| CO-17 | co_param_level_boundary.sh | PASS (860s) | PASS (862s) | 一致 |  |
| CO-18 | co_param_priority.sh | PASS (1227s) | PASS (4921s) | 一致 |  |
| CO-19 | co_unseq_select.sh | PASS (255s) | PASS (1214s) | 一致 |  |
| CO-20 | co_target_file_size.sh | PASS (328s) | PASS (522s) | 一致 |  |
| CO-21 | co_inner_total_size.sh | PASS (304s) | PASS (670s) | 一致 |  |
| CO-22 | co_task_queue.sh | PASS (430s) | PASS (2142s) | 一致 |  |
| CO-23 | co_threads.sh | PASS (667s) | PASS (2228s) | 一致 |  |
| CO-24 | co_aligned_batch.sh | PASS (335s) | PASS (1144s) | 一致 |  |
| CO-25 | co_rate_limit.sh | PASS (719s) | PASS (1691s) | 一致 |  |
| CO-26 | co_settle_select.sh | PASS (568s) | PASS (811s) | 一致 |  |
| CO-27 | co_basic_shapes.sh | PASS (674s) | PASS (1447s) | 一致 |  |
| CO-28 | co_table_unseq_cross.sh | PASS (421s) | PASS (497s) | 一致 |  |
| CO-29 | co_restart_recovery.sh | PASS (814s) | PASS (1686s) | 一致 |  |
| CO-30 | co_insertion_cross.sh | PASS (303s) | PASS (1182s) | 一致 |  |
| CO-31 | co_concurrent_io.sh | PASS (526s) | PASS (792s) | 一致 |  |
| CO-32 | co_auto_repair.sh | PASS (345s) | PASS (854s) | 一致 |  |
| CO-33 | co_repair_unsorted_load.sh | PASS (487s) | PASS (501s) | 一致 |  |
| CO-34 | co_scale_cascade.sh | PASS (217s) | PASS (228s) | 一致 |  |
| CO-35 | co_target_split_formula.sh | PASS (1054s) | PASS (1043s) | 一致 |  V2 fail=44 / V1 fail=1：已定性为用例 harness 缺陷（命令替换吞换行导致相位静默跳过），修复中 |
| CO-36 | co_fast_fake_overlap.sh | FAIL (4823s fail=20) | FAIL (5243s fail=19) | 一致 |  |
| CO-37 | co_aligned_grouping.sh | PASS (349s) | PASS (910s) | 一致 |  |
| CO-38 | co_level_search_gate.sh | FAIL (918s fail=2) | FAIL (1839s fail=7) | 一致 |  |
| CO-39 | co_priority_rules.sh | PASS (748s) | FAIL (3458s fail=2) | **分歧** | V1=PASS V2=FAIL |
| CO-40 | co_recovery_branches.sh | PASS (1172s) | PASS (2505s) | 一致 |  |
| CO-41 | co_object_ttl.sh | PASS (406s) | FAIL (659s fail=8) | **分歧** | V1=PASS V2=FAIL |
| CO-42 | co_fast_vs_default_perf.sh | PASS (1483s) | PASS (3508s) | 一致 |  |
| CO-43 | co_samename_aligned_flip.sh | PASS (585s) | PASS (859s) | 一致 |  |
| DT-01 | dt_tree_basic.sh | PASS (671s) | PASS (672s) | 一致 |  |
| DT-02 | dt_tree_negative.sh | PASS (310s) | FAIL (317s fail=2) | **分歧** | V1=PASS V2=FAIL |
| DT-03 | dt_tree_compaction.sh | PASS (720s) | PASS (720s) | 一致 |  |
| DT-04 | dt_tree_concurrent.sh | PASS (276s) | FAIL (286s fail=2) | **分歧** | V1=PASS V2=FAIL |
| DT-05 | dt_table_basic.sh | PASS (229s) | PASS (239s) | 一致 |  |
| DT-06 | dt_table_compaction.sh | PASS (295s) | PASS (282s) | 一致 |  |
| DT-07 | dt_view.sh | PASS (222s) | PASS (233s) | 一致 |  |
| DT-08 | dt_ha_disk_ro.sh | PASS (1023s) | FAIL (1527s fail=1) | **分歧** | V1=PASS V2=FAIL |
| DT-09 | dt_ha_stop_nodes.sh | PASS (1029s) | FAIL (931s fail=2) | **分歧** | V1=PASS V2=FAIL |

## 3. 作废清单（不参与当前结论）

（无）

## 4. 历史轨迹（各轮，按时间）

```
CO-01:
   2026-10-16T22:00:23+08:00  IoTConsensus    PASS     355s fail=0    test_result.csv
   2026-10-17T19:21:45+08:00  IoTConsensusV2  PASS     349s fail=0    test_result.csv
CO-02:
   2026-10-16T22:06:01+08:00  IoTConsensus    PASS     338s fail=0    test_result.csv
   2026-10-17T19:27:36+08:00  IoTConsensusV2  PASS     351s fail=0    test_result.csv
CO-03:
   2026-10-16T22:12:10+08:00  IoTConsensus    PASS     369s fail=0    test_result.csv
   2026-10-16T22:12:11+08:00  IoTConsensus    PASS     369s fail=0    test_result.csv
   2026-10-17T19:34:45+08:00  IoTConsensusV2  PASS     429s fail=0    test_result.csv
CO-04:
   2026-10-16T22:21:12+08:00  IoTConsensus    PASS     541s fail=0    test_result.csv
   2026-10-17T19:44:44+08:00  IoTConsensusV2  PASS     599s fail=0    test_result.csv
CO-05:
   2026-10-16T22:30:14+08:00  IoTConsensus    PASS     542s fail=0    test_result.csv
   2026-10-17T19:56:09+08:00  IoTConsensusV2  PASS     685s fail=0    test_result.csv
CO-06:
   2026-10-16T21:11:18+08:00  IoTConsensusV2  FAIL     971s fail=2    test_result_prev_20261016_215428.csv
   2026-10-16T22:42:40+08:00  IoTConsensus    PASS     746s fail=0    test_result.csv
   2026-10-17T20:11:59+08:00  IoTConsensusV2  FAIL     950s fail=2    test_result.csv
CO-07:
   2026-10-16T22:50:53+08:00  IoTConsensus    PASS     493s fail=0    test_result.csv
   2026-10-17T20:20:45+08:00  IoTConsensusV2  PASS     526s fail=0    test_result.csv
CO-08:
   2026-10-16T22:57:00+08:00  IoTConsensus    PASS     367s fail=0    test_result.csv
   2026-10-17T20:27:15+08:00  IoTConsensusV2  PASS     390s fail=0    test_result.csv
CO-09:
   2026-10-16T23:08:16+08:00  IoTConsensus    PASS     676s fail=0    test_result.csv
   2026-10-17T20:38:37+08:00  IoTConsensusV2  PASS     682s fail=0    test_result.csv
CO-10:
   2026-10-16T23:15:59+08:00  IoTConsensus    PASS     463s fail=0    test_result.csv
   2026-10-17T20:46:31+08:00  IoTConsensusV2  PASS     474s fail=0    test_result.csv
CO-11:
   2026-10-16T23:43:38+08:00  IoTConsensus    PASS    1659s fail=0    test_result.csv
   2026-10-17T21:14:09+08:00  IoTConsensusV2  PASS    1658s fail=0    test_result.csv
CO-12:
   2026-10-16T23:54:34+08:00  IoTConsensus    PASS     656s fail=0    test_result.csv
   2026-10-17T21:25:06+08:00  IoTConsensusV2  PASS     657s fail=0    test_result.csv
CO-13:
   2026-10-17T00:04:14+08:00  IoTConsensus    PASS     580s fail=0    test_result.csv
   2026-10-17T21:35:49+08:00  IoTConsensusV2  PASS     643s fail=0    test_result.csv
CO-14:
   2026-10-17T00:12:57+08:00  IoTConsensus    PASS     523s fail=0    test_result.csv
   2026-10-17T21:45:37+08:00  IoTConsensusV2  PASS     588s fail=0    test_result.csv
CO-15:
   2026-10-17T00:40:59+08:00  IoTConsensus    PASS    1682s fail=0    test_result.csv
   2026-10-17T22:15:19+08:00  IoTConsensusV2  FAIL    1782s fail=3    test_result.csv
CO-16:
   2026-10-17T00:56:13+08:00  IoTConsensus    PASS     914s fail=0    test_result.csv
   2026-10-17T22:31:13+08:00  IoTConsensusV2  PASS     954s fail=0    test_result.csv
CO-17:
   2026-10-17T01:10:33+08:00  IoTConsensus    PASS     860s fail=0    test_result.csv
   2026-10-17T22:45:35+08:00  IoTConsensusV2  PASS     861s fail=0    test_result.csv
   2026-10-17T22:45:35+08:00  IoTConsensusV2  PASS     862s fail=0    test_result.csv
CO-18:
   2026-10-17T01:31:00+08:00  IoTConsensus    PASS    1226s fail=0    test_result.csv
   2026-10-17T01:31:00+08:00  IoTConsensus    PASS    1227s fail=0    test_result.csv
   2026-10-18T00:07:36+08:00  IoTConsensusV2  PASS    4921s fail=0    test_result.csv
CO-19:
   2026-10-17T01:35:15+08:00  IoTConsensus    PASS     255s fail=0    test_result.csv
   2026-10-18T00:27:50+08:00  IoTConsensusV2  PASS    1214s fail=0    test_result.csv
CO-20:
   2026-10-17T01:40:43+08:00  IoTConsensus    PASS     328s fail=0    test_result.csv
   2026-10-18T00:36:32+08:00  IoTConsensusV2  PASS     522s fail=0    test_result.csv
CO-21:
   2026-10-17T01:45:47+08:00  IoTConsensus    PASS     304s fail=0    test_result.csv
   2026-10-18T00:47:42+08:00  IoTConsensusV2  PASS     670s fail=0    test_result.csv
CO-22:
   2026-10-17T01:52:57+08:00  IoTConsensus    PASS     430s fail=0    test_result.csv
   2026-10-17T01:52:58+08:00  IoTConsensus    PASS     430s fail=0    test_result.csv
   2026-10-18T01:23:24+08:00  IoTConsensusV2  PASS    2142s fail=0    test_result.csv
CO-23:
   2026-10-17T02:04:05+08:00  IoTConsensus    PASS     667s fail=0    test_result.csv
   2026-10-18T02:00:32+08:00  IoTConsensusV2  PASS    2228s fail=0    test_result.csv
CO-24:
   2026-10-17T02:09:40+08:00  IoTConsensus    PASS     335s fail=0    test_result.csv
   2026-10-18T02:19:36+08:00  IoTConsensusV2  PASS    1144s fail=0    test_result.csv
CO-25:
   2026-10-17T02:21:39+08:00  IoTConsensus    PASS     719s fail=0    test_result.csv
   2026-10-18T02:47:47+08:00  IoTConsensusV2  PASS    1691s fail=0    test_result.csv
CO-26:
   2026-10-17T02:31:07+08:00  IoTConsensus    PASS     568s fail=0    test_result.csv
   2026-10-18T03:01:18+08:00  IoTConsensusV2  PASS     811s fail=0    test_result.csv
CO-27:
   2026-10-17T02:42:21+08:00  IoTConsensus    PASS     674s fail=0    test_result.csv
   2026-10-18T03:25:25+08:00  IoTConsensusV2  PASS    1447s fail=0    test_result.csv
CO-28:
   2026-10-17T02:49:22+08:00  IoTConsensus    PASS     421s fail=0    test_result.csv
   2026-10-18T03:33:42+08:00  IoTConsensusV2  PASS     497s fail=0    test_result.csv
CO-29:
   2026-10-17T03:02:56+08:00  IoTConsensus    PASS     814s fail=0    test_result.csv
   2026-10-18T04:01:48+08:00  IoTConsensusV2  PASS    1686s fail=0    test_result.csv
CO-30:
   2026-10-17T03:07:59+08:00  IoTConsensus    PASS     303s fail=0    test_result.csv
   2026-10-18T04:21:30+08:00  IoTConsensusV2  PASS    1182s fail=0    test_result.csv
CO-31:
   2026-10-17T03:16:45+08:00  IoTConsensus    PASS     526s fail=0    test_result.csv
   2026-10-18T04:34:42+08:00  IoTConsensusV2  PASS     792s fail=0    test_result.csv
CO-32:
   2026-10-17T03:22:30+08:00  IoTConsensus    PASS     345s fail=0    test_result.csv
   2026-10-18T04:48:56+08:00  IoTConsensusV2  PASS     853s fail=0    test_result.csv
   2026-10-18T04:48:56+08:00  IoTConsensusV2  PASS     854s fail=0    test_result.csv
CO-33:
   2026-10-17T04:47:49+08:00  IoTConsensus    FAIL     508s fail=1    test_result.csv
   2026-10-18T06:24:04+08:00  IoTConsensusV2  PASS     501s fail=0    test_result.csv
   2026-10-18T22:52:46+08:00  IoTConsensus    PASS     487s fail=0    test_result.csv
CO-34:
   2026-10-17T04:51:26+08:00  IoTConsensus    PASS     217s fail=0    test_result.csv
   2026-10-18T06:27:52+08:00  IoTConsensusV2  PASS     228s fail=0    test_result.csv
CO-35:
   2026-10-17T05:07:51+08:00  IoTConsensus    FAIL     985s fail=18   test_result.csv
   2026-10-18T06:45:15+08:00  IoTConsensusV2  PASS    1043s fail=0    test_result.csv
   2026-10-18T23:10:20+08:00  IoTConsensus    PASS    1054s fail=0    test_result.csv
CO-36:
   2026-10-17T07:18:18+08:00  IoTConsensus    FAIL    4823s fail=20   test_result.csv
   2026-10-18T10:08:01+08:00  IoTConsensusV2  FAIL    5243s fail=19   test_result.csv
CO-37:
   2026-10-17T05:13:40+08:00  IoTConsensus    PASS     349s fail=0    test_result.csv
   2026-10-18T07:00:25+08:00  IoTConsensusV2  PASS     910s fail=0    test_result.csv
CO-38:
   2026-10-17T07:33:36+08:00  IoTConsensus    FAIL     918s fail=2    test_result.csv
   2026-10-18T10:38:40+08:00  IoTConsensusV2  FAIL    1839s fail=7    test_result.csv
CO-39:
   2026-10-17T07:46:04+08:00  IoTConsensus    PASS     748s fail=0    test_result.csv
   2026-10-18T11:36:18+08:00  IoTConsensusV2  FAIL    3458s fail=2    test_result.csv
CO-40:
   2026-10-17T05:33:12+08:00  IoTConsensus    PASS    1172s fail=0    test_result.csv
   2026-10-18T07:42:10+08:00  IoTConsensusV2  PASS    2505s fail=0    test_result.csv
CO-41:
   2026-10-17T07:52:50+08:00  IoTConsensus    PASS     406s fail=0    test_result.csv
   2026-10-18T11:47:17+08:00  IoTConsensusV2  FAIL     659s fail=8    test_result.csv
CO-42:
   2026-10-17T05:57:55+08:00  IoTConsensus    PASS    1483s fail=0    test_result.csv
   2026-10-18T08:40:38+08:00  IoTConsensusV2  PASS    3508s fail=0    test_result.csv
CO-43:
   2026-10-17T08:02:35+08:00  IoTConsensus    PASS     585s fail=0    test_result.csv
   2026-10-18T12:01:36+08:00  IoTConsensusV2  PASS     859s fail=0    test_result.csv
DT-01:
   2026-10-17T03:33:41+08:00  IoTConsensus    PASS     671s fail=0    test_result.csv
   2026-10-18T05:00:08+08:00  IoTConsensusV2  PASS     672s fail=0    test_result.csv
DT-02:
   2026-10-17T03:38:51+08:00  IoTConsensus    PASS     310s fail=0    test_result.csv
   2026-10-18T05:05:25+08:00  IoTConsensusV2  FAIL     317s fail=2    test_result.csv
DT-03:
   2026-10-17T03:50:51+08:00  IoTConsensus    PASS     720s fail=0    test_result.csv
   2026-10-18T05:17:25+08:00  IoTConsensusV2  PASS     720s fail=0    test_result.csv
DT-04:
   2026-10-17T03:55:27+08:00  IoTConsensus    PASS     276s fail=0    test_result.csv
   2026-10-18T05:22:11+08:00  IoTConsensusV2  FAIL     286s fail=2    test_result.csv
DT-05:
   2026-10-17T03:59:16+08:00  IoTConsensus    PASS     229s fail=0    test_result.csv
   2026-10-18T05:26:10+08:00  IoTConsensusV2  PASS     239s fail=0    test_result.csv
DT-06:
   2026-10-17T04:04:11+08:00  IoTConsensus    PASS     295s fail=0    test_result.csv
   2026-10-18T05:30:52+08:00  IoTConsensusV2  PASS     282s fail=0    test_result.csv
DT-07:
   2026-10-16T20:53:27+08:00  IoTConsensus    PASS     229s fail=0    test_result_prev_20261016_215428.csv
   2026-10-17T04:07:53+08:00  IoTConsensus    PASS     222s fail=0    test_result.csv
   2026-10-18T05:34:45+08:00  IoTConsensusV2  PASS     233s fail=0    test_result.csv
DT-08:
   2026-10-17T04:24:56+08:00  IoTConsensus    PASS    1023s fail=0    test_result.csv
   2026-10-18T06:00:12+08:00  IoTConsensusV2  FAIL    1527s fail=1    test_result.csv
DT-09:
   2026-10-17T04:39:21+08:00  IoTConsensus    FAIL     865s fail=2    test_result.csv
   2026-10-18T06:15:43+08:00  IoTConsensusV2  FAIL     931s fail=2    test_result.csv
   2026-10-18T22:44:38+08:00  IoTConsensus    PASS    1029s fail=0    test_result.csv
   2026-10-18T22:44:39+08:00  IoTConsensus    PASS    1029s fail=0    test_result.csv
```

## 5. 缺失项（需补跑）


## 6. 分歧用例

CO-06, CO-15, CO-39, CO-41, DT-02, DT-04, DT-08, DT-09
