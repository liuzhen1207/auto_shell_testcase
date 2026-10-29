#!/bin/bash
# 汇总新增用例最新一轮的 RESULT（状态/耗时/fail 数）
cd /data/iotdb/autotest/compaction_skill/results || exit 1
for c in co_param_priority co_task_queue co_rate_limit co_restart_recovery co_insertion_cross \
         co_target_file_size co_threads co_aligned_batch co_unseq_select co_table_unseq_cross \
         co_inner_total_size co_settle_select co_basic_shapes co_concurrent_io co_auto_repair; do
  f=$(ls -t ${c}_IoTConsensus_*.out 2>/dev/null | head -1)
  if [ -z "$f" ]; then echo "${c}: 无输出"; continue; fi
  line=$(grep -a "RESULT " "$f" | tail -1)
  if [ -z "$line" ]; then
    echo "${c}: 无 RESULT（可能仍在跑或异常退出） file=$f"
  else
    st=$(printf '%s' "$line" | grep -oE 'RESULT (PASS|FAIL)' | awk '{print $2}')
    ff=$(printf '%s' "$line" | grep -oE 'fail_flag=[0-9]+' | cut -d= -f2)
    el=$(printf '%s' "$line" | grep -oE 'elapsed=[0-9]+' | cut -d= -f2)
    printf '%-24s %-5s fail=%-3s elapsed=%ss\n' "$c" "$st" "$ff" "$el"
  fi
done
