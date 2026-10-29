#!/bin/bash
# 汇总新增用例（CO-18~CO-32）最新一轮的关键判据行
cd /data/iotdb/autotest/compaction_skill/results || exit 1
for c in co_param_priority co_task_queue co_rate_limit co_restart_recovery co_insertion_cross \
         co_target_file_size co_threads co_aligned_batch co_unseq_select co_table_unseq_cross \
         co_inner_total_size co_settle_select co_basic_shapes co_concurrent_io co_auto_repair; do
  f=$(ls -t ${c}_IoTConsensus_*.out 2>/dev/null | head -1)
  if [ -z "$f" ]; then echo "== $c :: (无输出)"; continue; fi
  res=$(grep -a RESULT "$f" | tail -1 | sed 's/^.*RESULT/RESULT/')
  ff=$(grep -ac FAIL "$f")
  echo "== $c :: ${res:-无RESULT} (FAIL行=$ff)"
  grep -a "PASS \|WARN \|FAIL " "$f" | grep -av "sync lag\|与基准一致\|停 192\|经 192\|日志无异常" | head -9 | sed 's/^/    /' | cut -c1-190
done
