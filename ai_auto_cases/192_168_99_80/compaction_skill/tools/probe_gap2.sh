#!/bin/bash
# 定点实验 2：单设备（只落一个 region）+ 全部批次递增时间戳（保证全在 sequence 空间），
# 验证 [L1(旧), L0(新)] 在 gap=1 时是否被合并出 L2。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_gap2"
DB=root.gaptest
export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_single_target,max_level_gap_in_inner_compaction=1"
cmp_cluster_prepare
log "  生效值：gap=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction) sel=$(cmp_eff "${DN[0]}" inner_seq_selector) cand=$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num) thr=$(cmp_eff "${DN[0]}" inner_compaction_total_file_num_threshold) interval=$(cmp_eff "${DN[0]}" compaction_schedule_interval_in_ms)"

sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null

dump(){ local tag=$1
  echo "--- [$tag] 各 DN 文件（space/db/region/partition/文件名）---"
  for h in "${DN[@]}"; do
    echo "  $h:"
    sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%p\n' 2>/dev/null | sed 's|.*/datanode/data/||' | sort" 2>/dev/null
  done
  echo "--- [$tag] 计数 seq/unseq/level 分布 ---"
  for h in "${DN[@]}"; do
    echo "  $h: seq=$(cmp_seq_cnt "$h" "$DB") unseq=$(cmp_unseq_cnt "$h" "$DB") lvls=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{print \$3}' | sort -n | uniq -c | tr '\n' ' '" 2>/dev/null)"
  done
  echo "--- [$tag] 压缩日志 ---"
  for h in "${DN[@]}"; do
    sshx "$h" "grep -hE '$DB-[0-9]+ \[Compaction\]' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | tail -3 | cut -c1-160" 2>/dev/null
  done
  echo "--- [$tag] finishes=$(cmp_inner_finish "$DB") tsfile=$(cmp_all_sum "$DB")"
}
write_batch(){ local b=$1 base=$2 k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  ensure_closed "$DB" 2 15 || true
}
NOW=$(now_ms)
log "--- 批 1（时间戳最小）---"
write_batch 1 "$NOW"
dump "after batch1"

log "--- 批 2（时间戳更大，应落同一个 sequence 空间）---"
write_batch 2 "$(( NOW + 20000 ))"
dump "after batch2"

log "--- 开 seq 内部合并，等 30s（期望两批 L0 → 1 个 L1）---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 30
dump "after merge window (expect L1)"

log "--- 批 3（时间戳再更大）→ 期望场景 [L1(旧), L0(新)] ---"
cmp_set_hot enable_seq_space_compaction false >/dev/null
write_batch 3 "$(( NOW + 40000 ))"
dump "after batch3"

log "--- 开合并 + gap=1，等 90s，期望出现 L2 ---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 90
dump "after 90s gap=1"

log "--- 热改 gap=2，再等 60s ---"
cmp_set_hot max_level_gap_in_inner_compaction 2 >/dev/null
log "  生效值=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)"
sleep 60
dump "after 60s gap=2"
echo "### 实验结束 $(date '+%F %T')"
