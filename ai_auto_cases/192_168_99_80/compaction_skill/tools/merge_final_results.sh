#!/bin/bash
# 把 CO-18~CO-32 / DT-01~DT-09 的最后一轮结果补进 results/final_results.csv（该文件是"每用例最后一条"的交付汇总）
set -u
cd /data/iotdb/autotest/compaction_skill/results || exit 1
CSV=test_result.csv
OUT=final_results.csv
[ -f "$CSV" ] || { echo "缺 $CSV"; exit 1; }
[ -f "$OUT" ] || echo 'caseName,result,elapsedSeconds,failCount,build,consensus,Time' >"$OUT"
add_row(){ local id=$1 case=$2 line
  line=$(awk -F, -v c="$case" '$4==c {l=$0} END{print l}' "$CSV")
  if [ -z "$line" ]; then echo "  [$id] 无记录（$case）"; return; fi
  local res el ff build cons t
  res=$(printf '%s' "$line" | awk -F, '{print $5}')
  el=$(printf '%s' "$line" | awk -F, '{print $6}')
  ff=$(printf '%s' "$line" | awk -F, '{print $7}')
  build=$(printf '%s' "$line" | awk -F, '{print $2}')
  cons=$(printf '%s' "$line" | awk -F, '{print $3}')
  t=$(printf '%s' "$line" | awk -F, '{print $1}')
  if grep -q "^$id," "$OUT"; then
    sed -i "s|^$id,.*|$id,$res,$el,$ff,$build,$cons,$t|" "$OUT"
    echo "  [$id] 已更新：$res ${el}s fail=$ff"
  else
    # 保持按 ID 排序插入：先追加再整体排序（表头单独处理）
    printf '%s\n' "$id,$res,$el,$ff,$build,$cons,$t" >>"$OUT"
    echo "  [$id] 已追加：$res ${el}s fail=$ff"
  fi
}
add_row CO-18 co_param_priority_IoTConsensus.sh
add_row CO-19 co_unseq_select_IoTConsensus.sh
add_row CO-20 co_target_file_size_IoTConsensus.sh
add_row CO-21 co_inner_total_size_IoTConsensus.sh
add_row CO-22 co_task_queue_IoTConsensus.sh
add_row CO-23 co_threads_IoTConsensus.sh
add_row CO-24 co_aligned_batch_IoTConsensus.sh
add_row CO-25 co_rate_limit_IoTConsensus.sh
add_row CO-26 co_settle_select_IoTConsensus.sh
add_row CO-27 co_basic_shapes_IoTConsensus.sh
add_row CO-28 co_table_unseq_cross_IoTConsensus.sh
add_row CO-29 co_restart_recovery_IoTConsensus.sh
add_row CO-30 co_insertion_cross_IoTConsensus.sh
add_row CO-31 co_concurrent_io_IoTConsensus.sh
add_row CO-32 co_auto_repair_IoTConsensus.sh
# DT 批：修改数据类型 × 合并 / 高可用（2026-10-14）
add_row DT-01 dt_tree_basic_IoTConsensus.sh
add_row DT-02 dt_tree_negative_IoTConsensus.sh
add_row DT-03 dt_tree_compaction_IoTConsensus.sh
add_row DT-04 dt_tree_concurrent_IoTConsensus.sh
add_row DT-05 dt_table_basic_IoTConsensus.sh
add_row DT-06 dt_table_compaction_IoTConsensus.sh
add_row DT-07 dt_view_IoTConsensus.sh
add_row DT-08 dt_ha_disk_ro_IoTConsensus.sh
add_row DT-09 dt_ha_stop_nodes_IoTConsensus.sh
# 排序（表头保留在第一行）
{ head -1 "$OUT"; tail -n +2 "$OUT" | sort -t, -k1,1; } >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"
cp -p "$CSV" test_result_all_rounds.csv
echo "--- final_results.csv ---"
cat "$OUT"
echo "--- 通过数 ---"
awk -F, 'NR>1{n++; if($2=="PASS")p++} END{printf "PASS=%d / 共 %d\n", p, n}' "$OUT"
