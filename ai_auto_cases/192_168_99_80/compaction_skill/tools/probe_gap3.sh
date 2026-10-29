#!/bin/bash
# 定点实验 4：用**默认选择器**（size_tiered_multi_target → NewSizeTieredCompactionSelector）
#   验证 max_level_gap_in_inner_compaction 的边界：
#     [L1,L0] gap=0 不合并 / gap=1 → L2
#     [L2,L0] gap=1 不合并 / gap=2 → L3
#   并对比 inner_compaction_total_file_num_threshold（任务文件数上限）。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_gap3"
DB=root.gap3

export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0"
cmp_cluster_prepare
log "  生效值：sel=$(cmp_eff "${DN[0]}" inner_seq_selector) gap=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction) cand=$(cmp_eff "${DN[0]}" inner_compaction_candidate_file_num) interval=$(cmp_eff "${DN[0]}" compaction_schedule_interval_in_ms)"

sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null

# 层级分布（L0/L1/L2/L3 计数），每个 DN 一行
lay_all(){ local h; for h in "${DN[@]}"; do
    printf '%s:%s ' "${h##*.}" "$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$1/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{c[\$3]++} END{printf \"%d/%d/%d/%d\", c[0]+0, c[1]+0, c[2]+0, c[3]+0}'" 2>/dev/null)"
  done; echo; }
lay_uni(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
wait_lay(){ local db=$1 want=$2 t=${3:-150} dl; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    if [ "$(lay_uni "$(lay_all "$db")")" = "$want " ]; then return 0; fi; sleep 3
  done; return 1; }
show(){ log "  布局=$1 finishes=$(cmp_inner_finish "$DB") files=$(cmp_all_sum "$DB")"; }

write_batch(){ local b=$1 base=$2 k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null; sleep 8; sq "flush;" >/dev/null; sleep 8; }
NOW=$(now_ms)

log "=== 场景 A：[L1, L0]，gap 边界 0 → 1 ==="
ln=0
for b in 1 2; do ln=$((ln+1)); write_batch "$b" "$(( NOW + b*20000 ))"
  wait_lay "$DB" "${ln}/0/0/0" 120 && show "批$b 后 = ${ln}/0/0/0 (L0×$ln)" || log "  WARN 批$b 后布局=$(lay_all "$DB")（期望 ${ln}/0/0/0）"
done
log "  开 seq 合并（gap=0，candidate=2）→ 期望合并出 1 个 L1"
cmp_set_hot enable_seq_space_compaction true >/dev/null
wait_lay "$DB" "0/1/0/0" 150 && show "两批合并后 = 0/1/0/0 (L1×1)" || log "  WARN 合并后布局=$(lay_all "$DB")（期望 0/1/0/0）"
cmp_set_hot enable_seq_space_compaction false >/dev/null
write_batch 3 "$(( NOW + 40000 ))"
wait_lay "$DB" "1/1/0/0" 120 && show "批3 后 = 1/1/0/0 ([L1, L0])" || log "  WARN 批3 后布局=$(lay_all "$DB")（期望 1/1/0/0）"
FIN0=$(cmp_inner_finish "$DB")
log "  gap=0 开合并，等 45s：期望**不合并**（|0-1| = 1 > 0）"
cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 45
show "gap=0 后 = $(lay_all "$DB")"; FIN1=$(cmp_inner_finish "$DB")
log "    finishes $FIN0 → $FIN1（相等=没合并）"
log "  热改 gap=1 → 期望 [L1, L0] 合并出 L2"
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
log "    gap 生效值=$(cmp_eff "${DN[0]}" max_level_gap_in_inner_compaction)"
wait_lay "$DB" "0/0/1/0" 120 && show "gap=1 后 = 0/0/1/0 (L2×1)" || log "  WARN gap=1 后布局=$(lay_all "$DB")（期望 0/0/1/0）"

log "=== 场景 B：[L2, L0]，gap 边界 1 → 2 ==="
cmp_set_hot enable_seq_space_compaction false >/dev/null
write_batch 4 "$(( NOW + 60000 ))"
wait_lay "$DB" "1/0/1/0" 120 && show "批4 后 = 1/0/1/0 ([L2, L0])" || log "  WARN 批4 后布局=$(lay_all "$DB")（期望 1/0/1/0）"
FIN2=$(cmp_inner_finish "$DB")
log "  gap=1 开合并，等 45s：期望**不合并**（|0-2| = 2 > 1）"
cmp_set_hot max_level_gap_in_inner_compaction 1 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 45
show "gap=1 后 = $(lay_all "$DB")"; FIN3=$(cmp_inner_finish "$DB")
log "    finishes $FIN2 → $FIN3（相等=没合并）"
log "  热改 gap=2 → 期望 [L2, L0] 合并出 L3"
cmp_set_hot max_level_gap_in_inner_compaction 2 >/dev/null
wait_lay "$DB" "0/0/0/1" 120 && show "gap=2 后 = 0/0/0/1 (L3×1)" || log "  WARN gap=2 后布局=$(lay_all "$DB")（期望 0/0/0/1）"
log "  数据指纹=$(cmp_fp_tree "$DB")"

log "=== 场景 C：任务文件数上限（inner_compaction_total_file_num_threshold）==="
thr_test(){ local db=$1 thr=$2 base=$3 n=$4 k
  cmp_set_hot enable_seq_space_compaction false >/dev/null
  cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
  cmp_set_hot enable_cross_space_compaction false >/dev/null
  cmp_set_hot inner_compaction_total_file_num_threshold "$thr" >/dev/null
  cmp_set_hot inner_compaction_candidate_file_num 2 >/dev/null
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null
  for ((k=1;k<=n;k++)); do
    local vals="" i
    for i in $(seq 1 200); do vals="$vals($(( base + k*20000 + i*10 )),$((i+k))),"; done
    sq "insert into $db.d1(time,s1) values ${vals%,};" >/dev/null; sq "flush;" >/dev/null; sleep 8
  done
  log "  [$db] threshold=$thr 写 $n 批 → 布局=$(lay_all "$db") files=$(cmp_all_sum "$db")"
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  sleep 60
  log "  [$db] 合并后布局=$(lay_all "$db") files=$(cmp_all_sum "$db")"
  local h
  for h in "${DN[@]}"; do
    sshx "$h" "grep -hF 'InnerSpaceCompaction task starts with' $(cmp_log_files) 2>/dev/null | grep -E '(^|[- ])${db}-[0-9]+' | tail -4 | cut -c1-150" 2>/dev/null
  done | sed 's/^/    日志: /'
}
thr_test "${DB}thr2" 2 "$(now_ms)" 4
thr_test "${DB}thr100" 100 "$(now_ms)" 4
echo "### 实验结束 $(date '+%F %T')"
