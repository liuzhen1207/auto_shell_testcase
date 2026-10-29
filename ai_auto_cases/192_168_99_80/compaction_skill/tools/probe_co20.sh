#!/bin/bash
# 定点探测：`target_compaction_file_size` 到底在什么场景下产出**多个**目标文件
#   A：单设备 4 文件（target=1KB vs 默认 2GB）
#   B：6 设备 × 2 批（同上）
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_co20"
export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0"
cmp_cluster_prepare
log "  默认 target=$(cmp_eff "${DN[0]}" target_compaction_file_size)"

run(){ local tag=$1 devs=$2 target=$3 db base b d k vals h
  db="root.probe20$tag"
  cmp_compaction_off
  cmp_set_hot target_compaction_file_size "$target" >/dev/null
  sq "create database $db;" >/dev/null
  for ((d=1;d<=devs;d++)); do sq "create timeseries $db.d$d.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null; done
  base=$(now_ms)
  for b in 1 2; do
    for ((d=1;d<=devs;d++)); do
      vals=""; for ((k=1;k<=200;k++)); do vals="$vals($(( base + b*20000 + k*10 )),$((k+b))),"; done
      sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null
    done
    sq "flush;" >/dev/null; sleep 10
  done
  sleep 12
  echo "  [$tag devs=$devs target=$target] 起点："
  for h in "${DN[@]}"; do echo "    $h: $(cmp_tsfile_list "$h" "$db" | tr '\n' ' ')"; done
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  sleep 75
  echo "  [$tag] 合并后（层级=$(cmp_lay "$db") files=$(cmp_all_sum "$db") 任务分布=$(cmp_task_nums "$db" inner)）："
  for h in "${DN[@]}"; do echo "    $h: $(cmp_tsfile_list "$h" "$db" | tr '\n' ' ')"; done
}
run a1 1 1024
run a2 1 2147483648
run b1 6 1024
run b2 6 2147483648
echo "### done $(date '+%F %T')"
