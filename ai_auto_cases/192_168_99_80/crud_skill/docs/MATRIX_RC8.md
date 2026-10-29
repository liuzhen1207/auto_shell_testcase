# 合并专项：52 条用例 × 双协议 结果总表（自动生成）

> 由 `tools/build_matrix_report.py` 生成；数据源 `results/*.csv` + `results/*.out`；作废规则见 `results/INVALIDATED.tsv`。**请勿手工编辑**。

## 1. 总览

| 协议 | PASS | FAIL | MISSING |
| --- | --- | --- | --- |
| IoTConsensus | 4 | 9 | 2 |
| IoTConsensusV2 | 4 | 9 | 2 |

双协议一致性：**一致 15** / 分歧 0 / 缺 0（共 15 条用例）
## 2. 主表

| 用例 | 脚本 | V1（IoTConsensus） | V2（IoTConsensusV2） | 一致性 | 备注 |
| --- | --- | --- | --- | --- | --- |
| CR-00 | cr_smoke.sh | PASS (341s) | PASS (330s) | 一致 |  |
| CR-01 | cr_timestamp_precision.sh | FAIL (631s fail=10) | FAIL (659s fail=10) | 一致 |  |
| CR-02 | cr_ts_partition_balance.sh | FAIL (391s fail=2) | FAIL (412s fail=2) | 一致 |  |
| CR-03 | cr_table_time_only.sh | FAIL (509s fail=8) | FAIL (1011s fail=8) | 一致 |  |
| CR-04 | cr_mod_shape.sh | PASS (329s) | PASS (728s) | 一致 |  |
| CR-05 | cr_mod_alloc_threshold.sh | PASS (389s) | PASS (1318s) | 一致 |  |
| CR-06 | cr_delete_concurrent_compaction.sh | FAIL (1423s fail=12) | FAIL (2427s fail=12) | 一致 |  |
| CR-07 | cr_delete_midstate.sh | UNKNOWN (1026s fail=) | UNKNOWN (1049s fail=) | 一致 |  |
| CR-08 | cr_delete_pipe.sh | FAIL (528s fail=4) | FAIL (748s fail=6) | 一致 |  |
| CR-09 | cr_mod_lifecycle.sh | FAIL (1133s fail=10) | FAIL (1371s fail=10) | 一致 |  |
| CR-10 | cr_delete_block_write.sh | FAIL (6743s fail=8) | FAIL (1561s fail=8) | 一致 |  |
| CR-11 | cr_object_manual_delete.sh | PASS (427s) | PASS (433s) | 一致 |  |
| CR-12 | cr_object_delete_negative.sh | UNKNOWN (698s fail=) | UNKNOWN (611s fail=) | 一致 |  |
| CR-13 | cr_load_lastcache.sh | FAIL (2093s fail=29) | FAIL (1448s fail=7) | 一致 |  |
| CR-14 | cr_load_pipe_last.sh | FAIL (3344s fail=113) | FAIL (1767s fail=96) | 一致 |  |

## 3. 作废清单（不参与当前结论）

（无）

## 4. 历史轨迹（各轮，按时间）

```
CR-00:
   2026-10-17T08:08:16+08:00  IoTConsensus    PASS     341s fail=0    test_result.csv
   2026-10-18T12:07:06+08:00  IoTConsensusV2  PASS     330s fail=0    test_result.csv
CR-01:
   2026-10-17T08:18:47+08:00  IoTConsensus    FAIL     631s fail=10   test_result.csv
   2026-10-18T12:18:05+08:00  IoTConsensusV2  FAIL     659s fail=10   test_result.csv
CR-02:
   2026-10-17T08:25:18+08:00  IoTConsensus    FAIL     391s fail=2    test_result.csv
   2026-10-18T12:24:57+08:00  IoTConsensusV2  FAIL     412s fail=2    test_result.csv
CR-03:
   2026-10-17T08:33:47+08:00  IoTConsensus    FAIL     509s fail=8    test_result.csv
   2026-10-18T12:41:48+08:00  IoTConsensusV2  FAIL    1011s fail=8    test_result.csv
CR-04:
   2026-10-17T08:39:16+08:00  IoTConsensus    PASS     329s fail=0    test_result.csv
   2026-10-18T12:53:56+08:00  IoTConsensusV2  PASS     728s fail=0    test_result.csv
CR-05:
   2026-10-17T08:45:45+08:00  IoTConsensus    PASS     389s fail=0    test_result.csv
   2026-10-18T13:15:54+08:00  IoTConsensusV2  PASS    1318s fail=0    test_result.csv
CR-06:
   2026-10-17T09:09:28+08:00  IoTConsensus    FAIL    1423s fail=12   test_result.csv
   2026-10-18T13:56:21+08:00  IoTConsensusV2  FAIL    2427s fail=12   test_result.csv
CR-07:
   2026-10-17T09:26:34+08:00  IoTConsensus    UNKNOWN   1026s fail=     test_result.csv
   2026-10-18T14:13:50+08:00  IoTConsensusV2  UNKNOWN   1049s fail=     test_result.csv
CR-08:
   2026-10-17T09:35:22+08:00  IoTConsensus    FAIL     528s fail=4    test_result.csv
   2026-10-18T14:26:18+08:00  IoTConsensusV2  FAIL     748s fail=6    test_result.csv
CR-09:
   2026-10-17T09:54:15+08:00  IoTConsensus    FAIL    1133s fail=10   test_result.csv
   2026-10-18T14:49:09+08:00  IoTConsensusV2  FAIL    1371s fail=10   test_result.csv
CR-10:
   2026-10-17T11:46:38+08:00  IoTConsensus    FAIL    6743s fail=8    test_result.csv
   2026-10-18T15:15:10+08:00  IoTConsensusV2  FAIL    1561s fail=8    test_result.csv
CR-11:
   2026-10-17T11:53:45+08:00  IoTConsensus    PASS     427s fail=0    test_result.csv
   2026-10-18T15:22:23+08:00  IoTConsensusV2  PASS     433s fail=0    test_result.csv
CR-12:
   2026-10-17T12:05:23+08:00  IoTConsensus    UNKNOWN    698s fail=     test_result.csv
   2026-10-18T15:32:34+08:00  IoTConsensusV2  UNKNOWN    611s fail=     test_result.csv
CR-13:
   2026-10-17T12:40:16+08:00  IoTConsensus    FAIL    2093s fail=29   test_result.csv
   2026-10-18T15:56:42+08:00  IoTConsensusV2  FAIL    1448s fail=7    test_result.csv
CR-14:
   2026-10-17T13:36:00+08:00  IoTConsensus    FAIL    3344s fail=113  test_result.csv
   2026-10-18T16:26:09+08:00  IoTConsensusV2  FAIL    1767s fail=96   test_result.csv
```

## 5. 缺失项（需补跑）


## 6. 分歧用例

（无）
