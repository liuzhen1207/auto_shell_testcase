#!/bin/bash
# 打包新增用例（CO-18~CO-32）最新一轮的完整输出 + 关键汇总，便于交付归档
set -u
cd /data/iotdb/autotest/compaction_skill/results || exit 1
TMP=/tmp/new_cases_evidence
rm -rf "$TMP"; mkdir -p "$TMP"
for c in co_param_priority co_unseq_select co_target_file_size co_inner_total_size co_task_queue \
         co_threads co_aligned_batch co_rate_limit co_settle_select co_basic_shapes \
         co_table_unseq_cross co_restart_recovery co_insertion_cross co_concurrent_io co_auto_repair; do
  f=$(ls -t ${c}_IoTConsensus_*.out 2>/dev/null | head -1)
  [ -n "$f" ] && cp -p "$f" "$TMP/"
done
cp -p final_results.csv test_result_all_rounds.csv "$TMP/" 2>/dev/null
cp -p B1_chain.out B2b_chain.out B3_chain.out B4_chain.out B5_chain.out B6_chain.out "$TMP/" 2>/dev/null
( cd /tmp && tar czf /tmp/new_cases_evidence.tgz new_cases_evidence )
ls -l /tmp/new_cases_evidence.tgz | cut -c1-80
ls "$TMP" | wc -l
