# 合并专项：52 条用例 × 双协议 结果总表（自动生成）

> 由 `tools/build_matrix_report.py` 生成；数据源 `results/*.csv` + `results/*.out`；作废规则见 `results/INVALIDATED.tsv`。**请勿手工编辑**。

## 1. 总览

| 协议 | PASS | FAIL | MISSING |
| --- | --- | --- | --- |
| IoTConsensus | 44 | 4 | 4 |
| IoTConsensusV2 | 29 | 4 | 19 |

双协议一致性：**一致 29** / 分歧 4 / 缺 19（共 52 条用例）

## 2. 主表

| 用例 | 脚本 | V1（IoTConsensus） | V2（IoTConsensusV2） | 一致性 | 备注 |
| --- | --- | --- | --- | --- | --- |
| CO-01 | co_tree_inner_smoke.sh | PASS (345s) | PASS (341s) | 一致 |  |
| CO-02 | co_table_inner_smoke.sh | PASS (345s) | PASS (350s) | 一致 |  |
| CO-03 | co_unseq_inner.sh | PASS (369s) | PASS (414s) | 一致 |  |
| CO-04 | co_cross_space.sh | PASS (543s) | FAIL (544s fail=1) | **分歧** | V1=PASS V2=FAIL |
| CO-05 | co_delete_data.sh | PASS (549s) | PASS (681s) | 一致 |  |
| CO-06 | co_metadata.sh | PASS (733s) | FAIL (933s fail=2) | **分歧** | V1=PASS V2=FAIL |
| CO-07 | co_data_types_encoding.sh | PASS (491s) | PASS (479s) | 一致 |  |
| CO-08 | co_aligned_null.sh | PASS (359s) | PASS (390s) | 一致 |  |
| CO-09 | co_conf_params.sh | PASS (676s) | PASS (681s) | 一致 |  |
| CO-10 | co_hot_reload.sh | PASS (467s) | PASS (470s) | 一致 |  |
| CO-11 | co_perf_baseline.sh | PASS (1673s) | FAIL (1635s fail=3) | **分歧** | V1=PASS V2=FAIL |
| CO-12 | co_remove_nodes.sh | PASS (653s) | PASS (646s) | 一致 |  |
| CO-13 | co_ttl_settle.sh | PASS (586s) | PASS (639s) | 一致 |  |
| CO-14 | co_ttl_table_settle.sh | PASS (577s) | PASS (599s) | 一致 |  |
| CO-15 | co_param_gate_matrix.sh | PASS (1627s) | PASS (1614s) | 一致 |  |
| CO-16 | co_param_selector.sh | PASS (897s) | PASS (966s) | 一致 |  |
| CO-17 | co_param_level_boundary.sh | PASS (743s) | FAIL (5425s fail=5) | **分歧** | V1=PASS V2=FAIL |
| CO-18 | co_param_priority.sh | PASS (1368s) | PASS (4941s) | 一致 |  |
| CO-19 | co_unseq_select.sh | PASS (285s) | PASS (1202s) | 一致 |  |
| CO-20 | co_target_file_size.sh | PASS (386s) | PASS (523s) | 一致 |  |
| CO-21 | co_inner_total_size.sh | PASS (331s) | PASS (675s) | 一致 |  |
| CO-22 | co_task_queue.sh | PASS (497s) | PASS (2159s) | 一致 |  |
| CO-23 | co_threads.sh | PASS (778s) | PASS (2238s) | 一致 |  |
| CO-24 | co_aligned_batch.sh | PASS (416s) | PASS (1137s) | 一致 |  |
| CO-25 | co_rate_limit.sh | PASS (702s) | PASS (1716s) | 一致 |  |
| CO-26 | co_settle_select.sh | PASS (588s) | PASS (787s) | 一致 |  |
| CO-27 | co_basic_shapes.sh | PASS (697s) | PASS (1443s) | 一致 |  |
| CO-28 | co_table_unseq_cross.sh | PASS (449s) | PASS (492s) | 一致 |  |
| CO-29 | co_restart_recovery.sh | PASS (874s) | PASS (1377s) | 一致 |  |
| CO-30 | co_insertion_cross.sh | PASS (287s) | PASS (1211s) | 一致 |  |
| CO-31 | co_concurrent_io.sh | PASS (555s) | PASS (795s) | 一致 |  |
| CO-32 | co_auto_repair.sh | PASS (364s) | PASS (851s) | 一致 |  |
| CO-33 | co_repair_unsorted_load.sh | — | — | 缺 | 缺：V1 V2 |
| CO-34 | co_scale_cascade.sh | — | — | 缺 | 缺：V1 V2 |
| CO-35 | co_target_split_formula.sh | — | — | 缺 | 缺：V1 V2 V2 fail=44 / V1 fail=1：已定性为用例 harness 缺陷（命令替换吞换行导致相位静默跳过），修复中 |
| CO-36 | co_fast_fake_overlap.sh | — | — | 缺 | 缺：V1 V2 |
| CO-37 | co_aligned_grouping.sh | PASS (354s) | PASS (900s) | 一致 |  |
| CO-38 | co_level_search_gate.sh | FAIL (977s fail=4) | — | 缺 | 缺：V2 |
| CO-39 | co_priority_rules.sh | PASS (752s) | — | 缺 | 缺：V2 |
| CO-40 | co_recovery_branches.sh | FAIL (1144s fail=4) | — | 缺 | 缺：V2 |
| CO-41 | co_object_ttl.sh | FAIL (404s fail=2) | — | 缺 | 缺：V2 |
| CO-42 | co_fast_vs_default_perf.sh | PASS (1483s) | — | 缺 | 缺：V2 |
| CO-43 | co_samename_aligned_flip.sh | PASS (571s) | — | 缺 | 缺：V2 |
| DT-01 | dt_tree_basic.sh | PASS (562s) | — | 缺 | 缺：V2 |
| DT-02 | dt_tree_negative.sh | PASS (310s) | — | 缺 | 缺：V2 |
| DT-03 | dt_tree_compaction.sh | PASS (691s) | — | 缺 | 缺：V2 |
| DT-04 | dt_tree_concurrent.sh | PASS (245s) | — | 缺 | 缺：V2 |
| DT-05 | dt_table_basic.sh | PASS (225s) | — | 缺 | 缺：V2 |
| DT-06 | dt_table_compaction.sh | PASS (276s) | — | 缺 | 缺：V2 |
| DT-07 | dt_view.sh | FAIL (220s fail=3) | — | 缺 | 缺：V2 |
| DT-08 | dt_ha_disk_ro.sh | PASS (975s) | — | 缺 | 缺：V2 |
| DT-09 | dt_ha_stop_nodes.sh | PASS (843s) | — | 缺 | 缺：V2 |

## 3. 作废清单（不参与当前结论）

| 用例 | 协议 | 来源 | 原因 |
| --- | --- | --- | --- |
| CO-33 | IoTConsensus | * | 远端脚本被部署截断5字节(c33_repair->c33_repai),start repair data 从未下发,fail=11为假失败;已修复待重跑 |
| CO-33 | IoTConsensusV2 | * | 同上部署截断(V2 1029s/fail=11) |
| CO-34 | IoTConsensus | * | grep -c ... || echo 0 在0匹配时输出两行,断言拿到"0\n0",fail=1为假失败(实测写入报错行数=0);已修复待重跑 |
| CO-34 | IoTConsensusV2 | * | 同上 grep 双行(V2 231s/fail=1) |
| CO-36 | IoTConsensus | * | 远端脚本被截断1字符(函数签名 ...del=$6 per -> ...del=$6 pe),set -u 下 $per 未定义,fail=23/20为假失败;已重新部署待重跑 |
| CO-35 | IoTConsensus | * | harness 缺陷:命令替换吞尾换行->两DN输出粘连->bash算术致命错误->相位后半段40+断言被静默跳过(V1 fail=1 并非"V1正常",V1三相同样中 value too great for base);修复中 |
| CO-35 | IoTConsensusV2 | * | 同上 harness 缺陷(V2 fail=44 系相位侥幸跑完后半段暴露的口径错误,非产品问题);修复中 |

## 4. 历史轨迹（各轮，按时间）

```
CO-01:
   2026-10-12T14:37:29+08:00  IoTConsensus    PASS     328s fail=0    test_result_all_rounds.csv
   2026-10-12T14:37:29+08:00  IoTConsensus    PASS     328s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T14:37:29+08:00  IoTConsensus    PASS     328s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     344s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     344s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     344s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T20:20:02+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:19:30+08:00  IoTConsensusV2  PASS     341s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T04:19:30+08:00  IoTConsensusV2  PASS     341s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-02:
   2026-10-12T14:42:55+08:00  IoTConsensus    PASS     326s fail=0    test_result_all_rounds.csv
   2026-10-12T14:42:55+08:00  IoTConsensus    PASS     326s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T14:42:55+08:00  IoTConsensus    PASS     326s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T20:25:47+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:25:47+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:25:47+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T20:25:48+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:25:48+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:25:48+08:00  IoTConsensus    PASS     345s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:25:20+08:00  IoTConsensusV2  PASS     350s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T04:25:20+08:00  IoTConsensusV2  PASS     350s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-03:
   2026-10-12T14:48:44+08:00  IoTConsensus    PASS     349s fail=0    test_result_all_rounds.csv
   2026-10-12T14:48:44+08:00  IoTConsensus    PASS     349s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T14:48:44+08:00  IoTConsensus    PASS     349s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T20:31:57+08:00  IoTConsensus    PASS     369s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:31:57+08:00  IoTConsensus    PASS     369s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:31:57+08:00  IoTConsensus    PASS     369s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:32:14+08:00  IoTConsensusV2  PASS     414s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T04:32:14+08:00  IoTConsensusV2  PASS     414s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-04:
   2026-10-12T14:56:00+08:00  IoTConsensus    FAIL     436s fail=1    test_result_all_rounds.csv
   2026-10-12T14:56:00+08:00  IoTConsensus    FAIL     436s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T14:56:00+08:00  IoTConsensus    FAIL     436s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T17:31:36+08:00  IoTConsensus    FAIL     601s fail=1    test_result_all_rounds.csv
   2026-10-12T17:31:36+08:00  IoTConsensus    FAIL     601s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:31:36+08:00  IoTConsensus    FAIL     601s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T19:18:02+08:00  IoTConsensus    PASS     527s fail=0    test_result_all_rounds.csv
   2026-10-12T19:18:02+08:00  IoTConsensus    PASS     527s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T19:18:02+08:00  IoTConsensus    PASS     527s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T20:41:00+08:00  IoTConsensus    PASS     543s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:41:00+08:00  IoTConsensus    PASS     543s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:41:00+08:00  IoTConsensus    PASS     543s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:41:18+08:00  IoTConsensusV2  FAIL     544s fail=1    test_result_before_targeted_20261016_095134.csv
   2026-10-16T04:41:18+08:00  IoTConsensusV2  FAIL     544s fail=1    test_result_rc7_v2_partial17_valid.csv
CO-05:
   2026-10-12T15:09:42+08:00  IoTConsensus    FAIL     822s fail=5    test_result_all_rounds.csv
   2026-10-12T15:09:42+08:00  IoTConsensus    FAIL     822s fail=5    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T15:09:42+08:00  IoTConsensus    FAIL     822s fail=5    test_result_rc6_plus_dt_latest.csv
   2026-10-12T17:42:21+08:00  IoTConsensus    FAIL     645s fail=1    test_result_all_rounds.csv
   2026-10-12T17:42:21+08:00  IoTConsensus    FAIL     645s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:42:21+08:00  IoTConsensus    FAIL     645s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T19:26:45+08:00  IoTConsensus    PASS     523s fail=0    test_result_all_rounds.csv
   2026-10-12T19:26:45+08:00  IoTConsensus    PASS     523s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T19:26:45+08:00  IoTConsensus    PASS     523s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T20:50:09+08:00  IoTConsensus    PASS     549s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:50:09+08:00  IoTConsensus    PASS     549s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:50:09+08:00  IoTConsensus    PASS     549s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:52:39+08:00  IoTConsensusV2  PASS     681s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T04:52:39+08:00  IoTConsensusV2  PASS     681s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-06:
   2026-10-12T15:24:21+08:00  IoTConsensus    FAIL     879s fail=3    test_result_all_rounds.csv
   2026-10-12T15:24:21+08:00  IoTConsensus    FAIL     879s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T15:24:21+08:00  IoTConsensus    FAIL     879s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-12T17:55:44+08:00  IoTConsensus    FAIL     803s fail=1    test_result_all_rounds.csv
   2026-10-12T17:55:44+08:00  IoTConsensus    FAIL     803s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:55:44+08:00  IoTConsensus    FAIL     803s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T17:55:45+08:00  IoTConsensus    FAIL     803s fail=1    test_result_all_rounds.csv
   2026-10-12T17:55:45+08:00  IoTConsensus    FAIL     803s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:55:45+08:00  IoTConsensus    FAIL     803s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T19:38:43+08:00  IoTConsensus    PASS     718s fail=0    test_result_all_rounds.csv
   2026-10-12T19:38:43+08:00  IoTConsensus    PASS     718s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T19:38:43+08:00  IoTConsensus    PASS     718s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T21:02:22+08:00  IoTConsensus    PASS     733s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T21:02:22+08:00  IoTConsensus    PASS     733s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T21:02:22+08:00  IoTConsensus    PASS     733s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T05:08:12+08:00  IoTConsensusV2  FAIL     933s fail=2    test_result_before_targeted_20261016_095134.csv
   2026-10-16T05:08:12+08:00  IoTConsensusV2  FAIL     933s fail=2    test_result_rc7_v2_partial17_valid.csv
CO-07:
   2026-10-12T15:33:59+08:00  IoTConsensus    FAIL     578s fail=74   test_result_all_rounds.csv
   2026-10-12T15:33:59+08:00  IoTConsensus    FAIL     578s fail=74   test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T15:33:59+08:00  IoTConsensus    FAIL     578s fail=74   test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:03:10+08:00  IoTConsensus    PASS     445s fail=0    test_result_all_rounds.csv
   2026-10-12T18:03:10+08:00  IoTConsensus    PASS     445s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:03:10+08:00  IoTConsensus    PASS     445s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T21:10:33+08:00  IoTConsensus    PASS     491s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T21:10:33+08:00  IoTConsensus    PASS     491s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T21:10:33+08:00  IoTConsensus    PASS     491s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T05:16:11+08:00  IoTConsensusV2  PASS     479s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T05:16:11+08:00  IoTConsensusV2  PASS     479s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-08:
   2026-10-12T15:40:20+08:00  IoTConsensus    FAIL     381s fail=1    test_result_all_rounds.csv
   2026-10-12T15:40:20+08:00  IoTConsensus    FAIL     381s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T15:40:20+08:00  IoTConsensus    FAIL     381s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:09:02+08:00  IoTConsensus    PASS     352s fail=0    test_result_all_rounds.csv
   2026-10-12T18:09:02+08:00  IoTConsensus    PASS     352s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:09:02+08:00  IoTConsensus    PASS     352s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T21:16:32+08:00  IoTConsensus    PASS     359s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T21:16:32+08:00  IoTConsensus    PASS     359s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T21:16:32+08:00  IoTConsensus    PASS     359s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T05:22:41+08:00  IoTConsensusV2  PASS     390s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T05:22:41+08:00  IoTConsensusV2  PASS     390s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-09:
   2026-10-12T15:53:05+08:00  IoTConsensus    FAIL     765s fail=1    test_result_all_rounds.csv
   2026-10-12T15:53:05+08:00  IoTConsensus    FAIL     765s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T15:53:05+08:00  IoTConsensus    FAIL     765s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:19:57+08:00  IoTConsensus    PASS     655s fail=0    test_result_all_rounds.csv
   2026-10-12T18:19:57+08:00  IoTConsensus    PASS     655s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:19:57+08:00  IoTConsensus    PASS     655s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T21:27:48+08:00  IoTConsensus    PASS     676s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T21:27:48+08:00  IoTConsensus    PASS     676s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T21:27:48+08:00  IoTConsensus    PASS     676s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T05:34:02+08:00  IoTConsensusV2  PASS     681s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T05:34:02+08:00  IoTConsensusV2  PASS     681s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-10:
   2026-10-12T16:14:28+08:00  IoTConsensus    FAIL    1283s fail=13   test_result_all_rounds.csv
   2026-10-12T16:14:28+08:00  IoTConsensus    FAIL    1283s fail=13   test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T16:14:28+08:00  IoTConsensus    FAIL    1283s fail=13   test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:27:27+08:00  IoTConsensus    PASS     450s fail=0    test_result_all_rounds.csv
   2026-10-12T18:27:27+08:00  IoTConsensus    PASS     450s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:27:27+08:00  IoTConsensus    PASS     450s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T21:35:35+08:00  IoTConsensus    PASS     467s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T21:35:35+08:00  IoTConsensus    PASS     467s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T21:35:35+08:00  IoTConsensus    PASS     467s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T05:41:52+08:00  IoTConsensusV2  PASS     470s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T05:41:52+08:00  IoTConsensusV2  PASS     470s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-11:
   2026-10-12T16:22:26+08:00  IoTConsensus    PASS     478s fail=0    test_result_all_rounds.csv
   2026-10-12T16:22:26+08:00  IoTConsensus    PASS     478s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T16:22:26+08:00  IoTConsensus    PASS     478s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T22:03:52+08:00  IoTConsensus    FAIL    1697s fail=1    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:03:52+08:00  IoTConsensus    FAIL    1697s fail=1    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:03:52+08:00  IoTConsensus    FAIL    1697s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T22:03:53+08:00  IoTConsensus    FAIL    1698s fail=1    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:03:53+08:00  IoTConsensus    FAIL    1698s fail=1    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:03:53+08:00  IoTConsensus    FAIL    1698s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T00:54:47+08:00  IoTConsensus    PASS     820s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:54:47+08:00  IoTConsensus    PASS     820s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T06:10:22+08:00  IoTConsensusV2  FAIL    1710s fail=1    test_result_before_targeted_20261016_095134.csv
   2026-10-16T06:10:22+08:00  IoTConsensusV2  FAIL    1710s fail=1    test_result_rc7_v2_partial17_valid.csv
   2026-10-16T10:19:27+08:00  IoTConsensus    PASS    1673s fail=0    test_result_after_co11_v1_20261016_101927.csv
   2026-10-16T10:19:27+08:00  IoTConsensus    PASS    1673s fail=0    test_result_co11_v1_20261016_101927.csv
   2026-10-16T10:46:42+08:00  IoTConsensusV2  FAIL    1635s fail=3    test_result_after_co11_v2_20261016_104642.csv
   2026-10-16T10:46:42+08:00  IoTConsensusV2  FAIL    1635s fail=3    test_result_co11_v2_20261016_104642.csv
CO-12:
   2026-10-12T16:39:36+08:00  IoTConsensus    FAIL    1030s fail=8    test_result_all_rounds.csv
   2026-10-12T16:39:36+08:00  IoTConsensus    FAIL    1030s fail=8    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T16:39:36+08:00  IoTConsensus    FAIL    1030s fail=8    test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:46:46+08:00  IoTConsensus    FAIL    1159s fail=7    test_result_all_rounds.csv
   2026-10-12T18:46:46+08:00  IoTConsensus    FAIL    1159s fail=7    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:46:46+08:00  IoTConsensus    FAIL    1159s fail=7    test_result_rc6_plus_dt_latest.csv
   2026-10-12T19:49:28+08:00  IoTConsensus    PASS     645s fail=0    test_result_all_rounds.csv
   2026-10-12T19:49:28+08:00  IoTConsensus    PASS     645s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T19:49:28+08:00  IoTConsensus    PASS     645s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     652s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     653s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     652s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     653s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     652s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T22:14:46+08:00  IoTConsensus    PASS     653s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T06:21:08+08:00  IoTConsensusV2  PASS     646s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T06:21:08+08:00  IoTConsensusV2  PASS     646s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-13:
   2026-10-12T17:10:34+08:00  IoTConsensus    FAIL     721s fail=3    test_result_all_rounds.csv
   2026-10-12T17:10:34+08:00  IoTConsensus    FAIL     721s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:10:34+08:00  IoTConsensus    FAIL     721s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-12T18:59:44+08:00  IoTConsensus    PASS     567s fail=0    test_result_all_rounds.csv
   2026-10-12T18:59:44+08:00  IoTConsensus    PASS     567s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T18:59:44+08:00  IoTConsensus    PASS     567s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     585s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     586s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     585s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     586s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     585s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T22:24:32+08:00  IoTConsensus    PASS     586s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T06:31:47+08:00  IoTConsensusV2  PASS     639s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T06:31:47+08:00  IoTConsensusV2  PASS     639s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-14:
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     660s fail=3    test_result_all_rounds.csv
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     661s fail=3    test_result_all_rounds.csv
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     660s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     661s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     660s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-12T17:21:35+08:00  IoTConsensus    FAIL     661s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-12T19:09:14+08:00  IoTConsensus    PASS     570s fail=0    test_result_all_rounds.csv
   2026-10-12T19:09:14+08:00  IoTConsensus    PASS     570s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-12T19:09:14+08:00  IoTConsensus    PASS     570s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T22:34:09+08:00  IoTConsensus    PASS     577s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T22:34:09+08:00  IoTConsensus    PASS     577s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T22:34:09+08:00  IoTConsensus    PASS     577s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T06:42:30+08:00  IoTConsensusV2  FAIL     643s fail=2    test_result_before_targeted_20261016_095134.csv
   2026-10-16T06:42:30+08:00  IoTConsensusV2  FAIL     643s fail=2    test_result_rc7_v2_partial17_valid.csv
   2026-10-16T10:56:39+08:00  IoTConsensusV2  PASS     597s fail=0    test_result_after_co14_v2_20261016_105639.csv
   2026-10-16T10:56:39+08:00  IoTConsensusV2  PASS     597s fail=0    test_result_co14_v2_20261016_105639.csv
   2026-10-16T11:06:38+08:00  IoTConsensusV2  PASS     599s fail=0    test_result_after_co14_rc6v2_20261016_110638.csv
   2026-10-16T11:06:38+08:00  IoTConsensusV2  PASS     599s fail=0    test_result_co14_rc6v2_20261016_110638.csv
CO-15:
   2026-10-13T09:22:31+08:00  IoTConsensus    UNKNOWN    435s fail=     test_result_all_rounds.csv
   2026-10-13T09:22:31+08:00  IoTConsensus    UNKNOWN    435s fail=     test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T09:22:31+08:00  IoTConsensus    UNKNOWN    435s fail=     test_result_rc6_plus_dt_latest.csv
   2026-10-13T09:51:00+08:00  IoTConsensus    PASS    1590s fail=0    test_result_all_rounds.csv
   2026-10-13T09:51:00+08:00  IoTConsensus    PASS    1590s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T09:51:00+08:00  IoTConsensus    PASS    1590s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-13T10:55:29+08:00  IoTConsensus    PASS    1653s fail=0    test_result_all_rounds.csv
   2026-10-13T10:55:29+08:00  IoTConsensus    PASS    1653s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T10:55:29+08:00  IoTConsensus    PASS    1653s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:01:16+08:00  IoTConsensus    PASS    1627s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:01:16+08:00  IoTConsensus    PASS    1627s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:01:16+08:00  IoTConsensus    PASS    1627s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T07:09:24+08:00  IoTConsensusV2  PASS    1614s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T07:09:24+08:00  IoTConsensusV2  PASS    1614s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-16:
   2026-10-13T09:22:58+08:00  IoTConsensus    UNKNOWN     27s fail=     test_result_all_rounds.csv
   2026-10-13T09:22:58+08:00  IoTConsensus    UNKNOWN     27s fail=     test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T09:22:58+08:00  IoTConsensus    UNKNOWN     27s fail=     test_result_rc6_plus_dt_latest.csv
   2026-10-13T11:10:23+08:00  IoTConsensus    FAIL     894s fail=3    test_result_all_rounds.csv
   2026-10-13T11:10:23+08:00  IoTConsensus    FAIL     894s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T11:10:23+08:00  IoTConsensus    FAIL     894s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-13T11:27:25+08:00  IoTConsensus    FAIL     882s fail=2    test_result_all_rounds.csv
   2026-10-13T11:27:25+08:00  IoTConsensus    FAIL     882s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T11:27:25+08:00  IoTConsensus    FAIL     882s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-13T11:45:49+08:00  IoTConsensus    PASS     897s fail=0    test_result_all_rounds.csv
   2026-10-13T11:45:49+08:00  IoTConsensus    PASS     897s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T11:45:49+08:00  IoTConsensus    PASS     897s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     896s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     897s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     896s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     897s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     896s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T23:16:13+08:00  IoTConsensus    PASS     897s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T07:25:30+08:00  IoTConsensusV2  PASS     966s fail=0    test_result_before_targeted_20261016_095134.csv
   2026-10-16T07:25:30+08:00  IoTConsensusV2  PASS     966s fail=0    test_result_rc7_v2_partial17_valid.csv
CO-17:
   2026-10-13T13:56:00+08:00  IoTConsensus    FAIL    1390s fail=2    test_result_all_rounds.csv
   2026-10-13T13:56:00+08:00  IoTConsensus    FAIL    1390s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T13:56:00+08:00  IoTConsensus    FAIL    1390s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-13T15:07:14+08:00  IoTConsensus    FAIL    1775s fail=3    test_result_all_rounds.csv
   2026-10-13T15:07:14+08:00  IoTConsensus    FAIL    1775s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T15:07:14+08:00  IoTConsensus    FAIL    1775s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-13T16:11:07+08:00  IoTConsensus    FAIL     715s fail=1    test_result_all_rounds.csv
   2026-10-13T16:11:07+08:00  IoTConsensus    FAIL     715s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T16:11:07+08:00  IoTConsensus    FAIL     715s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-13T16:24:53+08:00  IoTConsensus    PASS     718s fail=0    test_result_all_rounds.csv
   2026-10-13T16:24:53+08:00  IoTConsensus    PASS     718s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T16:24:53+08:00  IoTConsensus    PASS     718s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-13T17:48:20+08:00  IoTConsensus    PASS     722s fail=0    test_result_all_rounds.csv
   2026-10-13T17:48:20+08:00  IoTConsensus    PASS     722s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-13T17:48:20+08:00  IoTConsensus    PASS     722s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:28:36+08:00  IoTConsensus    PASS     743s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:28:36+08:00  IoTConsensus    PASS     743s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:28:36+08:00  IoTConsensus    PASS     743s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T08:55:55+08:00  IoTConsensusV2  FAIL    5425s fail=5    test_result_before_targeted_20261016_095134.csv
   2026-10-16T08:55:55+08:00  IoTConsensusV2  FAIL    5425s fail=5    test_result_rc7_v2_partial17_valid.csv
CO-18:
   2026-10-14T12:07:43+08:00  IoTConsensus    FAIL    1900s fail=1    test_result_all_rounds.csv
   2026-10-14T12:07:43+08:00  IoTConsensus    FAIL    1900s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T12:07:43+08:00  IoTConsensus    FAIL    1900s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T13:32:15+08:00  IoTConsensus    FAIL    1246s fail=1    test_result_all_rounds.csv
   2026-10-14T13:32:15+08:00  IoTConsensus    FAIL    1246s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T13:32:15+08:00  IoTConsensus    FAIL    1246s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T14:16:47+08:00  IoTConsensus    PASS    1258s fail=0    test_result_all_rounds.csv
   2026-10-14T14:16:47+08:00  IoTConsensus    PASS    1258s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T14:16:47+08:00  IoTConsensus    PASS    1258s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T14:24:15+08:00  IoTConsensus    PASS    1368s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T14:24:15+08:00  IoTConsensus    PASS    1368s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T14:24:15+08:00  IoTConsensus    PASS    1368s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T14:24:15+08:00  IoTConsensus    PASS    1368s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T14:24:15+08:00  IoTConsensus    PASS    1368s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T13:14:13+08:00  IoTConsensusV2  PASS    4941s fail=0    test_result.csv
CO-19:
   2026-10-14T10:20:22+08:00  IoTConsensus    PASS     264s fail=0    test_result_all_rounds.csv
   2026-10-14T10:20:22+08:00  IoTConsensus    PASS     264s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T10:20:22+08:00  IoTConsensus    PASS     264s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T14:29:00+08:00  IoTConsensus    PASS     285s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T14:29:00+08:00  IoTConsensus    PASS     285s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T14:29:00+08:00  IoTConsensus    PASS     285s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T14:29:00+08:00  IoTConsensus    PASS     285s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T14:29:00+08:00  IoTConsensus    PASS     285s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T13:34:15+08:00  IoTConsensusV2  PASS    1202s fail=0    test_result.csv
CO-20:
   2026-10-14T09:14:44+08:00  IoTConsensus    FAIL     577s fail=2    test_result_all_rounds.csv
   2026-10-14T09:14:44+08:00  IoTConsensus    FAIL     577s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T09:14:44+08:00  IoTConsensus    FAIL     577s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T10:35:16+08:00  IoTConsensus    PASS     325s fail=0    test_result_all_rounds.csv
   2026-10-14T10:35:16+08:00  IoTConsensus    PASS     325s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T10:35:16+08:00  IoTConsensus    PASS     325s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T14:35:26+08:00  IoTConsensus    PASS     386s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T14:35:26+08:00  IoTConsensus    PASS     386s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T14:35:26+08:00  IoTConsensus    PASS     386s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T14:35:26+08:00  IoTConsensus    PASS     386s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T14:35:26+08:00  IoTConsensus    PASS     386s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T13:42:58+08:00  IoTConsensusV2  PASS     523s fail=0    test_result.csv
CO-21:
   2026-10-14T09:19:45+08:00  IoTConsensus    PASS     301s fail=0    test_result_all_rounds.csv
   2026-10-14T09:19:45+08:00  IoTConsensus    PASS     301s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T09:19:45+08:00  IoTConsensus    PASS     301s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T14:40:57+08:00  IoTConsensus    PASS     331s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T14:40:57+08:00  IoTConsensus    PASS     331s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T14:40:57+08:00  IoTConsensus    PASS     331s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T14:40:57+08:00  IoTConsensus    PASS     331s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T14:40:57+08:00  IoTConsensus    PASS     331s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T13:54:13+08:00  IoTConsensusV2  PASS     675s fail=0    test_result.csv
CO-22:
   2026-10-14T12:37:53+08:00  IoTConsensus    PASS    1810s fail=0    test_result_all_rounds.csv
   2026-10-14T12:37:53+08:00  IoTConsensus    PASS    1810s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T12:37:53+08:00  IoTConsensus    PASS    1810s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-14T13:49:51+08:00  IoTConsensus    FAIL    1056s fail=2    test_result_all_rounds.csv
   2026-10-14T13:49:51+08:00  IoTConsensus    FAIL    1056s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T13:49:51+08:00  IoTConsensus    FAIL    1056s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T14:24:20+08:00  IoTConsensus    PASS     453s fail=0    test_result_all_rounds.csv
   2026-10-14T14:24:20+08:00  IoTConsensus    PASS     453s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T14:24:20+08:00  IoTConsensus    PASS     453s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T14:49:14+08:00  IoTConsensus    PASS     497s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T14:49:14+08:00  IoTConsensus    PASS     497s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T14:49:14+08:00  IoTConsensus    PASS     497s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T14:49:14+08:00  IoTConsensus    PASS     497s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T14:49:14+08:00  IoTConsensus    PASS     497s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T14:30:12+08:00  IoTConsensusV2  PASS    2159s fail=0    test_result.csv
CO-23:
   2026-10-14T10:46:17+08:00  IoTConsensus    PASS     661s fail=0    test_result_all_rounds.csv
   2026-10-14T10:46:17+08:00  IoTConsensus    PASS     661s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T10:46:17+08:00  IoTConsensus    PASS     661s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:02:12+08:00  IoTConsensus    PASS     778s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:02:12+08:00  IoTConsensus    PASS     778s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:02:12+08:00  IoTConsensus    PASS     778s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:02:12+08:00  IoTConsensus    PASS     778s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:02:12+08:00  IoTConsensus    PASS     778s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T15:07:30+08:00  IoTConsensusV2  PASS    2238s fail=0    test_result.csv
CO-24:
   2026-10-14T10:15:58+08:00  IoTConsensus    PASS     395s fail=0    test_result_all_rounds.csv
   2026-10-14T10:15:58+08:00  IoTConsensus    PASS     395s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T10:15:58+08:00  IoTConsensus    PASS     395s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:09:08+08:00  IoTConsensus    PASS     416s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:09:08+08:00  IoTConsensus    PASS     416s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:09:08+08:00  IoTConsensus    PASS     416s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:09:08+08:00  IoTConsensus    PASS     416s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:09:08+08:00  IoTConsensus    PASS     416s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T15:26:27+08:00  IoTConsensusV2  PASS    1137s fail=0    test_result.csv
CO-25:
   2026-10-14T12:49:36+08:00  IoTConsensus    PASS     703s fail=0    test_result_all_rounds.csv
   2026-10-14T12:49:36+08:00  IoTConsensus    PASS     703s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T12:49:36+08:00  IoTConsensus    PASS     703s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:20:50+08:00  IoTConsensus    PASS     702s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:20:50+08:00  IoTConsensus    PASS     702s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:20:50+08:00  IoTConsensus    PASS     702s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:20:50+08:00  IoTConsensus    PASS     702s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:20:50+08:00  IoTConsensus    PASS     702s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T15:55:03+08:00  IoTConsensusV2  PASS    1716s fail=0    test_result.csv
CO-26:
   2026-10-14T09:28:46+08:00  IoTConsensus    PASS     541s fail=0    test_result_all_rounds.csv
   2026-10-14T09:28:46+08:00  IoTConsensus    PASS     541s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T09:28:46+08:00  IoTConsensus    PASS     541s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:30:38+08:00  IoTConsensus    PASS     588s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:30:38+08:00  IoTConsensus    PASS     588s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:30:38+08:00  IoTConsensus    PASS     588s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:30:38+08:00  IoTConsensus    PASS     588s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:30:38+08:00  IoTConsensus    PASS     588s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T16:08:10+08:00  IoTConsensusV2  PASS     787s fail=0    test_result.csv
CO-27:
   2026-10-14T09:05:07+08:00  IoTConsensus    PASS     661s fail=0    test_result_all_rounds.csv
   2026-10-14T09:05:07+08:00  IoTConsensus    PASS     661s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T09:05:07+08:00  IoTConsensus    PASS     661s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:48:19+08:00  IoTConsensus    PASS     697s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:48:19+08:00  IoTConsensus    PASS     697s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:48:19+08:00  IoTConsensus    PASS     697s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:48:19+08:00  IoTConsensus    PASS     697s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:48:19+08:00  IoTConsensus    PASS     697s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T16:32:13+08:00  IoTConsensusV2  PASS    1443s fail=0    test_result.csv
CO-28:
   2026-10-14T10:27:23+08:00  IoTConsensus    PASS     421s fail=0    test_result_all_rounds.csv
   2026-10-14T10:27:23+08:00  IoTConsensus    PASS     421s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T10:27:23+08:00  IoTConsensus    PASS     421s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:55:48+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:55:48+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:55:48+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:55:48+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:55:48+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-15T15:55:49+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:55:49+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:55:49+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:55:49+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:55:49+08:00  IoTConsensus    PASS     449s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T16:40:25+08:00  IoTConsensusV2  PASS     492s fail=0    test_result.csv
CO-29:
   2026-10-14T13:03:12+08:00  IoTConsensus    PASS     816s fail=0    test_result_all_rounds.csv
   2026-10-14T13:03:12+08:00  IoTConsensus    PASS     816s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T13:03:12+08:00  IoTConsensus    PASS     816s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T16:10:23+08:00  IoTConsensus    PASS     874s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T16:10:23+08:00  IoTConsensus    PASS     874s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T16:10:23+08:00  IoTConsensus    PASS     874s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T16:10:23+08:00  IoTConsensus    PASS     874s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T16:10:23+08:00  IoTConsensus    PASS     874s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T17:03:22+08:00  IoTConsensusV2  PASS    1377s fail=0    test_result.csv
CO-30:
   2026-10-14T11:19:55+08:00  IoTConsensus    FAIL    1009s fail=1    test_result_all_rounds.csv
   2026-10-14T11:19:55+08:00  IoTConsensus    FAIL    1009s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T11:19:55+08:00  IoTConsensus    FAIL    1009s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T13:07:26+08:00  IoTConsensus    PASS     254s fail=0    test_result_all_rounds.csv
   2026-10-14T13:07:26+08:00  IoTConsensus    PASS     254s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T13:07:26+08:00  IoTConsensus    PASS     254s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T16:15:10+08:00  IoTConsensus    PASS     287s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T16:15:10+08:00  IoTConsensus    PASS     287s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T16:15:10+08:00  IoTConsensus    PASS     287s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T16:15:10+08:00  IoTConsensus    PASS     287s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T16:15:10+08:00  IoTConsensus    PASS     287s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T17:23:33+08:00  IoTConsensusV2  PASS    1211s fail=0    test_result.csv
CO-31:
   2026-10-14T11:28:51+08:00  IoTConsensus    PASS     536s fail=0    test_result_all_rounds.csv
   2026-10-14T11:28:51+08:00  IoTConsensus    PASS     536s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T11:28:51+08:00  IoTConsensus    PASS     536s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T16:24:25+08:00  IoTConsensus    PASS     555s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T16:24:25+08:00  IoTConsensus    PASS     555s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T16:24:25+08:00  IoTConsensus    PASS     555s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T16:24:25+08:00  IoTConsensus    PASS     555s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T16:24:25+08:00  IoTConsensus    PASS     555s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T17:36:48+08:00  IoTConsensusV2  PASS     795s fail=0    test_result.csv
CO-32:
   2026-10-14T11:01:57+08:00  IoTConsensus    PASS     365s fail=0    test_result_all_rounds.csv
   2026-10-14T11:01:57+08:00  IoTConsensus    PASS     365s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T11:01:57+08:00  IoTConsensus    PASS     365s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T15:36:42+08:00  IoTConsensus    PASS     364s fail=0    test_result_rc7_param2_scene_20261015_140127.csv
   2026-10-15T15:36:42+08:00  IoTConsensus    PASS     364s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T15:36:42+08:00  IoTConsensus    PASS     364s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T15:36:42+08:00  IoTConsensus    PASS     364s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T15:36:42+08:00  IoTConsensus    PASS     364s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T17:50:59+08:00  IoTConsensusV2  PASS     851s fail=0    test_result.csv
CO-33:
   2026-10-15T16:42:35+08:00  IoTConsensus    FAIL    1067s fail=11   test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-15T16:42:35+08:00  IoTConsensus    FAIL    1067s fail=11   test_result_rc7_v1_full_20261016_004107.csv   [作废]
   2026-10-15T16:42:35+08:00  IoTConsensus    FAIL    1067s fail=11   test_result_rc7_v1_partial_20261015_201417.csv   [作废]
   2026-10-15T16:42:35+08:00  IoTConsensus    FAIL    1067s fail=11   test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T01:15:08+08:00  IoTConsensus    FAIL    1001s fail=11   test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-16T01:15:08+08:00  IoTConsensus    FAIL    1001s fail=11   test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T18:08:08+08:00  IoTConsensusV2  FAIL    1029s fail=11   test_result.csv   [作废]
CO-34:
   2026-10-15T16:46:31+08:00  IoTConsensus    FAIL     236s fail=1    test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-15T16:46:31+08:00  IoTConsensus    FAIL     236s fail=1    test_result_rc7_v1_full_20261016_004107.csv   [作废]
   2026-10-15T16:46:31+08:00  IoTConsensus    FAIL     236s fail=1    test_result_rc7_v1_partial_20261015_201417.csv   [作废]
   2026-10-15T16:46:31+08:00  IoTConsensus    FAIL     236s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T01:18:38+08:00  IoTConsensus    FAIL     210s fail=1    test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-16T01:18:38+08:00  IoTConsensus    FAIL     210s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T18:11:59+08:00  IoTConsensusV2  FAIL     231s fail=1    test_result.csv   [作废]
CO-35:
   2026-10-15T16:56:41+08:00  IoTConsensus    FAIL     555s fail=1    test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-15T16:56:41+08:00  IoTConsensus    FAIL     555s fail=1    test_result_rc7_v1_full_20261016_004107.csv   [作废]
   2026-10-15T16:56:41+08:00  IoTConsensus    FAIL     555s fail=1    test_result_rc7_v1_partial_20261015_201417.csv   [作废]
   2026-10-15T16:56:41+08:00  IoTConsensus    FAIL     555s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T01:27:51+08:00  IoTConsensus    FAIL     553s fail=1    test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-16T01:27:51+08:00  IoTConsensus    FAIL     553s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T18:47:57+08:00  IoTConsensusV2  FAIL    2158s fail=44   test_result.csv   [作废]
CO-36:
   2026-10-15T19:20:15+08:00  IoTConsensus    FAIL    4773s fail=23   test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-15T19:20:15+08:00  IoTConsensus    FAIL    4773s fail=23   test_result_rc7_v1_full_20261016_004107.csv   [作废]
   2026-10-15T19:20:15+08:00  IoTConsensus    FAIL    4773s fail=23   test_result_rc7_v1_partial_20261015_201417.csv   [作废]
   2026-10-15T19:20:15+08:00  IoTConsensus    FAIL    4773s fail=23   test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
   2026-10-16T03:38:16+08:00  IoTConsensus    FAIL    4844s fail=20   test_result_rc7_v1_archived_20261016_041349.csv   [作废]
   2026-10-16T03:38:16+08:00  IoTConsensus    FAIL    4844s fail=20   test_result_rc7_v1_rerun_20261016_041349.csv   [作废]
CO-37:
   2026-10-15T17:02:32+08:00  IoTConsensus    FAIL     351s fail=3    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T17:02:32+08:00  IoTConsensus    FAIL     351s fail=3    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T17:02:32+08:00  IoTConsensus    FAIL     351s fail=3    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T17:02:32+08:00  IoTConsensus    FAIL     351s fail=3    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T01:33:45+08:00  IoTConsensus    PASS     354s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T01:33:45+08:00  IoTConsensus    PASS     354s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T19:02:57+08:00  IoTConsensusV2  PASS     900s fail=0    test_result.csv
CO-38:
   2026-10-15T19:35:43+08:00  IoTConsensus    FAIL     928s fail=11   test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T19:35:43+08:00  IoTConsensus    FAIL     928s fail=11   test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T19:35:43+08:00  IoTConsensus    FAIL     928s fail=11   test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T19:35:43+08:00  IoTConsensus    FAIL     928s fail=11   test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T03:54:33+08:00  IoTConsensus    FAIL     977s fail=4    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T03:54:33+08:00  IoTConsensus    FAIL     977s fail=4    test_result_rc7_v1_rerun_20261016_041349.csv
CO-39:
   2026-10-15T19:48:23+08:00  IoTConsensus    FAIL     760s fail=3    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T19:48:23+08:00  IoTConsensus    FAIL     760s fail=3    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T19:48:23+08:00  IoTConsensus    FAIL     760s fail=3    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T19:48:23+08:00  IoTConsensus    FAIL     760s fail=3    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:07:05+08:00  IoTConsensus    PASS     752s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T04:07:05+08:00  IoTConsensus    PASS     752s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
CO-40:
   2026-10-15T17:35:55+08:00  IoTConsensus    FAIL    2003s fail=5    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T17:35:55+08:00  IoTConsensus    FAIL    2003s fail=5    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T17:35:55+08:00  IoTConsensus    FAIL    2003s fail=5    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T17:35:55+08:00  IoTConsensus    FAIL    2003s fail=5    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T01:52:49+08:00  IoTConsensus    FAIL    1144s fail=4    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T01:52:49+08:00  IoTConsensus    FAIL    1144s fail=4    test_result_rc7_v1_rerun_20261016_041349.csv
CO-41:
   2026-10-15T20:04:00+08:00  IoTConsensus    FAIL     937s fail=4    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:04:00+08:00  IoTConsensus    FAIL     937s fail=4    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:04:00+08:00  IoTConsensus    FAIL     937s fail=4    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T20:04:00+08:00  IoTConsensus    FAIL     937s fail=4    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T04:13:49+08:00  IoTConsensus    FAIL     404s fail=2    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T04:13:49+08:00  IoTConsensus    FAIL     404s fail=2    test_result_rc7_v1_rerun_20261016_041349.csv
CO-42:
   2026-10-15T18:00:42+08:00  IoTConsensus    FAIL    1487s fail=1    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T18:00:42+08:00  IoTConsensus    FAIL    1487s fail=1    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T18:00:42+08:00  IoTConsensus    FAIL    1487s fail=1    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T18:00:42+08:00  IoTConsensus    FAIL    1487s fail=1    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T02:17:32+08:00  IoTConsensus    PASS    1483s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T02:17:32+08:00  IoTConsensus    PASS    1483s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
CO-43:
   2026-10-15T20:13:31+08:00  IoTConsensus    PASS     571s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T20:13:31+08:00  IoTConsensus    PASS     571s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T20:13:31+08:00  IoTConsensus    PASS     571s fail=0    test_result_rc7_v1_partial_20261015_201417.csv
   2026-10-15T20:13:31+08:00  IoTConsensus    PASS     571s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-01:
   2026-10-14T16:33:54+08:00  IoTConsensus    FAIL     669s fail=30   test_result_all_rounds.csv
   2026-10-14T16:33:54+08:00  IoTConsensus    FAIL     669s fail=30   test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T16:33:54+08:00  IoTConsensus    FAIL     669s fail=30   test_result_rc6_plus_dt_latest.csv
   2026-10-14T17:08:24+08:00  IoTConsensus    FAIL     627s fail=30   test_result_all_rounds.csv
   2026-10-14T17:08:24+08:00  IoTConsensus    FAIL     627s fail=30   test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T17:08:24+08:00  IoTConsensus    FAIL     627s fail=30   test_result_rc6_plus_dt_latest.csv
   2026-10-14T18:14:31+08:00  IoTConsensus    FAIL     674s fail=5    test_result_all_rounds.csv
   2026-10-14T18:14:31+08:00  IoTConsensus    FAIL     674s fail=5    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T18:14:31+08:00  IoTConsensus    FAIL     674s fail=5    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:02:25+08:00  IoTConsensus    PASS     693s fail=0    test_result_all_rounds.csv
   2026-10-14T19:02:25+08:00  IoTConsensus    PASS     693s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:02:25+08:00  IoTConsensus    PASS     693s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T11:45:44+08:00  IoTConsensus    PASS     828s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-15T11:45:44+08:00  IoTConsensus    PASS     828s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:37:58+08:00  IoTConsensus    PASS     562s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:37:58+08:00  IoTConsensus    PASS     562s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:37:58+08:00  IoTConsensus    PASS     562s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-02:
   2026-10-14T16:38:55+08:00  IoTConsensus    FAIL     301s fail=7    test_result_all_rounds.csv
   2026-10-14T16:38:55+08:00  IoTConsensus    FAIL     301s fail=7    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T16:38:55+08:00  IoTConsensus    FAIL     301s fail=7    test_result_rc6_plus_dt_latest.csv
   2026-10-14T17:13:04+08:00  IoTConsensus    FAIL     280s fail=3    test_result_all_rounds.csv
   2026-10-14T17:13:04+08:00  IoTConsensus    FAIL     280s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T17:13:04+08:00  IoTConsensus    FAIL     280s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-14T18:19:30+08:00  IoTConsensus    PASS     299s fail=0    test_result_all_rounds.csv
   2026-10-14T18:19:30+08:00  IoTConsensus    PASS     299s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T18:19:30+08:00  IoTConsensus    PASS     299s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T11:51:12+08:00  IoTConsensus    PASS     328s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-15T11:51:12+08:00  IoTConsensus    PASS     328s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:43:08+08:00  IoTConsensus    PASS     310s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:43:08+08:00  IoTConsensus    PASS     310s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:43:08+08:00  IoTConsensus    PASS     310s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-03:
   2026-10-14T17:26:47+08:00  IoTConsensus    FAIL     823s fail=4    test_result_all_rounds.csv
   2026-10-14T17:26:47+08:00  IoTConsensus    FAIL     823s fail=4    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T17:26:47+08:00  IoTConsensus    FAIL     823s fail=4    test_result_rc6_plus_dt_latest.csv
   2026-10-14T18:33:41+08:00  IoTConsensus    FAIL     851s fail=4    test_result_all_rounds.csv
   2026-10-14T18:33:41+08:00  IoTConsensus    FAIL     851s fail=4    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T18:33:41+08:00  IoTConsensus    FAIL     851s fail=4    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:13:58+08:00  IoTConsensus    FAIL     693s fail=2    test_result_all_rounds.csv
   2026-10-14T19:13:58+08:00  IoTConsensus    FAIL     693s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:13:58+08:00  IoTConsensus    FAIL     693s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:38:12+08:00  IoTConsensus    PASS     752s fail=0    test_result_all_rounds.csv
   2026-10-14T19:38:12+08:00  IoTConsensus    PASS     752s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:38:12+08:00  IoTConsensus    PASS     752s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:54:39+08:00  IoTConsensus    PASS     691s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:54:39+08:00  IoTConsensus    PASS     691s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:54:39+08:00  IoTConsensus    PASS     691s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-04:
   2026-10-14T18:38:02+08:00  IoTConsensus    FAIL     261s fail=1    test_result_all_rounds.csv
   2026-10-14T18:38:02+08:00  IoTConsensus    FAIL     261s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T18:38:02+08:00  IoTConsensus    FAIL     261s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:18:23+08:00  IoTConsensus    FAIL     265s fail=1    test_result_all_rounds.csv
   2026-10-14T19:18:23+08:00  IoTConsensus    FAIL     265s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:18:23+08:00  IoTConsensus    FAIL     265s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:44:08+08:00  IoTConsensus    FAIL     356s fail=1    test_result_all_rounds.csv
   2026-10-14T19:44:08+08:00  IoTConsensus    FAIL     356s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:44:08+08:00  IoTConsensus    FAIL     356s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:57:59+08:00  IoTConsensus    PASS     265s fail=0    test_result_all_rounds.csv
   2026-10-14T19:57:59+08:00  IoTConsensus    PASS     265s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:57:59+08:00  IoTConsensus    PASS     265s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-15T23:58:44+08:00  IoTConsensus    PASS     245s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-15T23:58:44+08:00  IoTConsensus    PASS     245s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-15T23:58:44+08:00  IoTConsensus    PASS     245s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-05:
   2026-10-14T16:42:31+08:00  IoTConsensus    FAIL     216s fail=1    test_result_all_rounds.csv
   2026-10-14T16:42:31+08:00  IoTConsensus    FAIL     216s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T16:42:31+08:00  IoTConsensus    FAIL     216s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T17:30:31+08:00  IoTConsensus    PASS     224s fail=0    test_result_all_rounds.csv
   2026-10-14T17:30:31+08:00  IoTConsensus    PASS     224s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T17:30:31+08:00  IoTConsensus    PASS     224s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-14T19:48:04+08:00  IoTConsensus    PASS     236s fail=0    test_result_all_rounds.csv
   2026-10-14T19:48:04+08:00  IoTConsensus    PASS     236s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:48:04+08:00  IoTConsensus    PASS     236s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-16T00:02:29+08:00  IoTConsensus    PASS     225s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:02:29+08:00  IoTConsensus    PASS     225s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:02:29+08:00  IoTConsensus    PASS     225s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-06:
   2026-10-14T19:53:01+08:00  IoTConsensus    PASS     297s fail=0    test_result_all_rounds.csv
   2026-10-14T19:53:01+08:00  IoTConsensus    PASS     297s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T19:53:01+08:00  IoTConsensus    PASS     297s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-16T00:07:05+08:00  IoTConsensus    PASS     276s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:07:05+08:00  IoTConsensus    PASS     276s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:07:05+08:00  IoTConsensus    PASS     276s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-07:
   2026-10-14T16:46:20+08:00  IoTConsensus    FAIL     229s fail=2    test_result_all_rounds.csv
   2026-10-14T16:46:20+08:00  IoTConsensus    FAIL     229s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T16:46:20+08:00  IoTConsensus    FAIL     229s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T17:34:18+08:00  IoTConsensus    FAIL     227s fail=2    test_result_all_rounds.csv
   2026-10-14T17:34:18+08:00  IoTConsensus    FAIL     227s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T17:34:18+08:00  IoTConsensus    FAIL     227s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T20:01:55+08:00  IoTConsensus    FAIL     236s fail=3    test_result_all_rounds.csv
   2026-10-14T20:01:55+08:00  IoTConsensus    FAIL     236s fail=3    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T20:01:55+08:00  IoTConsensus    FAIL     236s fail=3    test_result_rc6_plus_dt_latest.csv
   2026-10-16T00:10:48+08:00  IoTConsensus    FAIL     223s fail=3    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:10:48+08:00  IoTConsensus    FAIL     223s fail=3    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:10:48+08:00  IoTConsensus    FAIL     223s fail=3    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T00:58:27+08:00  IoTConsensus    FAIL     220s fail=3    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:58:27+08:00  IoTConsensus    FAIL     220s fail=3    test_result_rc7_v1_rerun_20261016_041349.csv
DT-08:
   2026-10-14T20:29:56+08:00  IoTConsensus    PASS     491s fail=0    test_result_all_rounds.csv
   2026-10-14T20:29:56+08:00  IoTConsensus    PASS     491s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T20:29:56+08:00  IoTConsensus    PASS     491s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-14T20:54:03+08:00  IoTConsensus    FAIL     483s fail=1    test_result_all_rounds.csv
   2026-10-14T20:54:03+08:00  IoTConsensus    FAIL     483s fail=1    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T20:54:03+08:00  IoTConsensus    FAIL     483s fail=1    test_result_rc6_plus_dt_latest.csv
   2026-10-14T21:17:10+08:00  IoTConsensus    FAIL    1225s fail=2    test_result_all_rounds.csv
   2026-10-14T21:17:10+08:00  IoTConsensus    FAIL    1225s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T21:17:10+08:00  IoTConsensus    FAIL    1225s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T21:39:24+08:00  IoTConsensus    FAIL    1105s fail=2    test_result_all_rounds.csv
   2026-10-14T21:39:24+08:00  IoTConsensus    FAIL    1105s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T21:39:24+08:00  IoTConsensus    FAIL    1105s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T21:58:21+08:00  IoTConsensus    PASS    1022s fail=0    test_result_all_rounds.csv
   2026-10-14T21:58:21+08:00  IoTConsensus    PASS    1022s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T21:58:21+08:00  IoTConsensus    PASS    1022s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-16T00:27:03+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:27:03+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:27:03+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
   2026-10-16T00:27:04+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:27:04+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:27:04+08:00  IoTConsensus    PASS     975s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
DT-09:
   2026-10-14T20:18:59+08:00  IoTConsensus    FAIL     962s fail=2    test_result_all_rounds.csv
   2026-10-14T20:18:59+08:00  IoTConsensus    FAIL     962s fail=2    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T20:18:59+08:00  IoTConsensus    FAIL     962s fail=2    test_result_rc6_plus_dt_latest.csv
   2026-10-14T20:44:08+08:00  IoTConsensus    PASS     852s fail=0    test_result_all_rounds.csv
   2026-10-14T20:44:08+08:00  IoTConsensus    PASS     852s fail=0    test_result_rc6_plus_dt_20261015_140127.csv
   2026-10-14T20:44:08+08:00  IoTConsensus    PASS     852s fail=0    test_result_rc6_plus_dt_latest.csv
   2026-10-16T00:41:07+08:00  IoTConsensus    PASS     843s fail=0    test_result_rc7_v1_archived_20261016_041349.csv
   2026-10-16T00:41:07+08:00  IoTConsensus    PASS     843s fail=0    test_result_rc7_v1_full_20261016_004107.csv
   2026-10-16T00:41:07+08:00  IoTConsensus    PASS     843s fail=0    test_result_rc7_v1_rerun_20261016_041349.csv
```

## 5. 缺失项（需补跑）

- CO-33 / IoTConsensus
- CO-33 / IoTConsensusV2
- CO-34 / IoTConsensus
- CO-34 / IoTConsensusV2
- CO-35 / IoTConsensus
- CO-35 / IoTConsensusV2
- CO-36 / IoTConsensus
- CO-36 / IoTConsensusV2
- CO-38 / IoTConsensusV2
- CO-39 / IoTConsensusV2
- CO-40 / IoTConsensusV2
- CO-41 / IoTConsensusV2
- CO-42 / IoTConsensusV2
- CO-43 / IoTConsensusV2
- DT-01 / IoTConsensusV2
- DT-02 / IoTConsensusV2
- DT-03 / IoTConsensusV2
- DT-04 / IoTConsensusV2
- DT-05 / IoTConsensusV2
- DT-06 / IoTConsensusV2
- DT-07 / IoTConsensusV2
- DT-08 / IoTConsensusV2
- DT-09 / IoTConsensusV2

## 6. 分歧用例

CO-04, CO-06, CO-11, CO-17
