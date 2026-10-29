# 合并专项：52 条用例 × 双协议 结果总表（自动生成）

> 由 `tools/build_matrix_report.py` 生成；数据源 `results/*.csv` + `results/*.out`；作废规则见 `results/INVALIDATED.tsv`。**请勿手工编辑**。

## 1. 总览

| 协议 | PASS | FAIL | MISSING |
| --- | --- | --- | --- |
| IoTConsensus | 3 | 17 | 7 |
| IoTConsensusV2 | 3 | 17 | 7 |

双协议一致性：**一致 27** / 分歧 0 / 缺 0（共 27 条用例）
## 2. 主表

| 用例 | 脚本 | V1（IoTConsensus） | V2（IoTConsensusV2） | 一致性 | 备注 |
| --- | --- | --- | --- | --- | --- |
| W-00 | wal_smoke.sh | PASS (490s) | PASS (491s) | 一致 |  |
| W-01 | wal_mode_matrix.sh | PASS (657s) | PASS (788s) | 一致 |  |
| W-02 | wal_mode_disable_rejected.sh | FAIL (353s fail=1) | FAIL (492s fail=1) | 一致 |  |
| W-03 | wal_mode_restart_only.sh | FAIL (460s fail=4) | FAIL (475s fail=4) | 一致 |  |
| W-04 | wal_recovery_kill9.sh | UNKNOWN (0s fail=) | UNKNOWN (0s fail=) | 一致 |  |
| W-05 | wal_recovery_flush_boundary.sh | FAIL (2721s fail=28) | FAIL (2801s fail=28) | 一致 |  |
| W-06 | wal_recovery_dn_down.sh | UNKNOWN (27s fail=) | UNKNOWN (27s fail=) | 一致 |  |
| W-07 | wal_recovery_metadata.sh | UNKNOWN (25s fail=) | UNKNOWN (26s fail=) | 一致 |  |
| W-08 | wal_file_rotate.sh | UNKNOWN (26s fail=) | UNKNOWN (26s fail=) | 一致 |  |
| W-09 | wal_buffer_size.sh | UNKNOWN (26s fail=) | UNKNOWN (25s fail=) | 一致 |  |
| W-10 | wal_node_alloc.sh | UNKNOWN (25s fail=) | UNKNOWN (26s fail=) | 一致 |  |
| W-11 | wal_compress_toggle.sh | FAIL (862s fail=3) | FAIL (913s fail=7) | 一致 |  |
| W-12 | wal_compress_recovery.sh | FAIL (2000s fail=17) | FAIL (2077s fail=19) | 一致 |  |
| W-13 | wal_compress_mixed.sh | FAIL (780s fail=4) | FAIL (1065s fail=4) | 一致 |  |
| W-14 | wal_cleanup_period.sh | FAIL (1102s fail=2) | FAIL (1098s fail=2) | 一致 |  |
| W-15 | wal_min_effective_ratio.sh | FAIL (1199s fail=3) | FAIL (1187s fail=3) | 一致 |  |
| W-16 | wal_memtable_snapshot.sh | FAIL (564s fail=4) | FAIL (677s fail=6) | 一致 |  |
| W-17 | wal_throttle.sh | FAIL (761s fail=3) | FAIL (769s fail=7) | 一致 |  |
| W-18 | wal_queue_memory.sh | FAIL (1004s fail=7) | FAIL (1053s fail=7) | 一致 |  |
| W-19 | wal_object_recovery.sh | UNKNOWN (0s fail=) | UNKNOWN (0s fail=) | 一致 |  |
| W-20 | wal_object_load_restart.sh | FAIL (1102s fail=12) | FAIL (1118s fail=12) | 一致 |  |
| W-21 | wal_param_invalid.sh | FAIL (1285s fail=13) | FAIL (1286s fail=11) | 一致 |  |
| W-22 | wal_param_hotload.sh | PASS (771s) | PASS (830s) | 一致 |  |
| W-23 | wal_metrics.sh | FAIL (943s fail=4) | FAIL (946s fail=4) | 一致 |  |
| W-24 | wal_dir_config.sh | FAIL (1077s fail=3) | FAIL (1141s fail=5) | 一致 |  |
| W-25 | wal_disk_readonly.sh | FAIL (322s fail=1) | FAIL (453s fail=3) | 一致 |  |
| W-26 | wal_consensus_matrix.sh | FAIL (1813s fail=20) | FAIL (1806s fail=20) | 一致 |  |

## 3. 作废清单（不参与当前结论）

（无）

## 4. 历史轨迹（各轮，按时间）

```
W-00:
   2026-10-17T13:44:10+08:00  IoTConsensus    PASS     490s fail=0    test_result.csv
   2026-10-18T16:34:20+08:00  IoTConsensusV2  PASS     491s fail=0    test_result.csv
W-01:
   2026-10-17T13:55:07+08:00  IoTConsensus    PASS     657s fail=0    test_result.csv
   2026-10-18T16:47:28+08:00  IoTConsensusV2  PASS     788s fail=0    test_result.csv
W-02:
   2026-10-17T14:01:00+08:00  IoTConsensus    FAIL     352s fail=1    test_result.csv
   2026-10-17T14:01:00+08:00  IoTConsensus    FAIL     353s fail=1    test_result.csv
   2026-10-18T16:55:40+08:00  IoTConsensusV2  FAIL     492s fail=1    test_result.csv
W-03:
   2026-10-17T14:08:40+08:00  IoTConsensus    FAIL     460s fail=4    test_result.csv
   2026-10-18T17:03:35+08:00  IoTConsensusV2  FAIL     475s fail=4    test_result.csv
W-04:
   2026-10-17T14:08:40+08:00  IoTConsensus    UNKNOWN      0s fail=     test_result.csv
   2026-10-18T17:03:35+08:00  IoTConsensusV2  UNKNOWN      0s fail=     test_result.csv
W-05:
   2026-10-17T14:54:01+08:00  IoTConsensus    FAIL    2721s fail=28   test_result.csv
   2026-10-18T17:50:16+08:00  IoTConsensusV2  FAIL    2801s fail=28   test_result.csv
W-06:
   2026-10-17T14:54:28+08:00  IoTConsensus    UNKNOWN     27s fail=     test_result.csv
   2026-10-18T17:50:43+08:00  IoTConsensusV2  UNKNOWN     27s fail=     test_result.csv
W-07:
   2026-10-17T14:54:53+08:00  IoTConsensus    UNKNOWN     25s fail=     test_result.csv
   2026-10-18T17:51:09+08:00  IoTConsensusV2  UNKNOWN     26s fail=     test_result.csv
W-08:
   2026-10-17T14:55:19+08:00  IoTConsensus    UNKNOWN     26s fail=     test_result.csv
   2026-10-18T17:51:35+08:00  IoTConsensusV2  UNKNOWN     26s fail=     test_result.csv
W-09:
   2026-10-17T14:55:45+08:00  IoTConsensus    UNKNOWN     26s fail=     test_result.csv
   2026-10-18T17:52:00+08:00  IoTConsensusV2  UNKNOWN     25s fail=     test_result.csv
W-10:
   2026-10-17T14:56:10+08:00  IoTConsensus    UNKNOWN     25s fail=     test_result.csv
   2026-10-18T17:52:26+08:00  IoTConsensusV2  UNKNOWN     26s fail=     test_result.csv
W-11:
   2026-10-17T15:10:32+08:00  IoTConsensus    FAIL     862s fail=3    test_result.csv
   2026-10-18T18:07:39+08:00  IoTConsensusV2  FAIL     913s fail=7    test_result.csv
W-12:
   2026-10-17T15:43:52+08:00  IoTConsensus    FAIL    2000s fail=17   test_result.csv
   2026-10-18T18:42:16+08:00  IoTConsensusV2  FAIL    2077s fail=19   test_result.csv
W-13:
   2026-10-17T15:56:52+08:00  IoTConsensus    FAIL     780s fail=4    test_result.csv
   2026-10-17T15:56:53+08:00  IoTConsensus    FAIL     780s fail=4    test_result.csv
   2026-10-18T19:00:01+08:00  IoTConsensusV2  FAIL    1065s fail=4    test_result.csv
W-14:
   2026-10-17T16:15:15+08:00  IoTConsensus    FAIL    1102s fail=2    test_result.csv
   2026-10-18T19:18:19+08:00  IoTConsensusV2  FAIL    1098s fail=2    test_result.csv
W-15:
   2026-10-17T16:35:14+08:00  IoTConsensus    FAIL    1199s fail=3    test_result.csv
   2026-10-18T19:38:06+08:00  IoTConsensusV2  FAIL    1187s fail=3    test_result.csv
W-16:
   2026-10-17T16:44:38+08:00  IoTConsensus    FAIL     564s fail=4    test_result.csv
   2026-10-18T19:49:23+08:00  IoTConsensusV2  FAIL     676s fail=6    test_result.csv
   2026-10-18T19:49:23+08:00  IoTConsensusV2  FAIL     677s fail=6    test_result.csv
W-17:
   2026-10-17T16:57:19+08:00  IoTConsensus    FAIL     761s fail=3    test_result.csv
   2026-10-18T20:02:12+08:00  IoTConsensusV2  FAIL     769s fail=7    test_result.csv
W-18:
   2026-10-17T17:14:03+08:00  IoTConsensus    FAIL    1004s fail=7    test_result.csv
   2026-10-18T20:19:45+08:00  IoTConsensusV2  FAIL    1053s fail=7    test_result.csv
W-19:
   2026-10-17T17:14:03+08:00  IoTConsensus    UNKNOWN      0s fail=     test_result.csv
   2026-10-18T20:19:45+08:00  IoTConsensusV2  UNKNOWN      0s fail=     test_result.csv
W-20:
   2026-10-17T17:32:25+08:00  IoTConsensus    FAIL    1102s fail=12   test_result.csv
   2026-10-18T20:38:23+08:00  IoTConsensusV2  FAIL    1118s fail=12   test_result.csv
W-21:
   2026-10-17T17:53:50+08:00  IoTConsensus    FAIL    1285s fail=13   test_result.csv
   2026-10-18T20:59:49+08:00  IoTConsensusV2  FAIL    1286s fail=11   test_result.csv
W-22:
   2026-10-17T18:06:41+08:00  IoTConsensus    PASS     771s fail=0    test_result.csv
   2026-10-18T21:13:39+08:00  IoTConsensusV2  PASS     830s fail=0    test_result.csv
W-23:
   2026-10-17T18:22:24+08:00  IoTConsensus    FAIL     943s fail=4    test_result.csv
   2026-10-18T21:29:25+08:00  IoTConsensusV2  FAIL     946s fail=4    test_result.csv
W-24:
   2026-10-17T18:40:21+08:00  IoTConsensus    FAIL    1077s fail=3    test_result.csv
   2026-10-18T21:48:26+08:00  IoTConsensusV2  FAIL    1141s fail=5    test_result.csv
W-25:
   2026-10-17T18:45:41+08:00  IoTConsensus    FAIL     320s fail=1    test_result.csv
   2026-10-17T18:45:43+08:00  IoTConsensus    FAIL     322s fail=1    test_result.csv
   2026-10-18T21:55:57+08:00  IoTConsensusV2  FAIL     451s fail=3    test_result.csv
   2026-10-18T21:55:59+08:00  IoTConsensusV2  FAIL     453s fail=3    test_result.csv
W-26:
   2026-10-17T19:15:56+08:00  IoTConsensusV2  FAIL    1813s fail=20   test_result.csv
   2026-10-17T19:15:56+08:00  IoTConsensus    FAIL    1813s fail=20   test_result.csv
   2026-10-18T22:26:05+08:00  IoTConsensusV2  FAIL    1806s fail=20   test_result.csv
```

## 5. 缺失项（需补跑）


## 6. 分歧用例

（无）
