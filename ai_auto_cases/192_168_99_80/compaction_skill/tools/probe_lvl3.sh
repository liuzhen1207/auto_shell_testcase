#!/bin/bash
# 定点实验 3：层级合并能力
#   A) 4 个 L0 文件（gap=0，candidate=2）→ 期望：两两合并出 2 个 L1，再 [L1,L1] → L2（1 个文件）
#   B) 之后写 1 批新 L0（gap=2）→ 期望：若层级混并可用，则产出更高层级
# 复用当前已运行的集群（不再重启）。
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_lvl3"
DB=root.lvltest
cmp_compaction_off
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null
write_batch(){ local b=$1 base=$2 k vals=""
  for ((k=1;k<=200;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null; }
dump(){ local tag=$1
  echo "--- [$tag] ---"
  for h in "${DN[@]}"; do
    echo "  $h: $(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$DB/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '{print \$3}' | sort -n | uniq -c | tr '\n' ' '" 2>/dev/null)"
  done
  echo "  finishes=$(cmp_inner_finish "$DB") files=$(cmp_all_sum "$DB")  (层级计数：level×文件数)"
}
NOW=$(now_ms)
log "--- 写 4 批（合并全关），期望 4×L0 ---"
for b in 1 2 3 4; do write_batch "$b" "$(( NOW + b*20000 ))"; done
sleep 20
dump "写完 4 批（合并关）"

log "--- gap=0 + candidate=2 开 seq 合并：期望 2×L1 → [L1,L1] → L2 ---"
cmp_set_hot inner_compaction_candidate_file_num 2 >/dev/null
cmp_set_hot max_level_gap_in_inner_compaction 0 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
for i in $(seq 1 6); do sleep 15; dump "gap=0 开合并 ${i}×15s"; done

log "--- 停合并，写第 5 批 → 场景 [L2/L1, L0]；再 gap=2 开合并 ---"
cmp_set_hot enable_seq_space_compaction false >/dev/null
write_batch 5 "$(( NOW + 120000 ))"
sleep 20
dump "写完第 5 批（合并关）"
cmp_set_hot max_level_gap_in_inner_compaction 2 >/dev/null
cmp_set_hot enable_seq_space_compaction true >/dev/null
for i in $(seq 1 6); do sleep 15; dump "gap=2 开合并 ${i}×15s"; done
echo "### done $(date '+%F %T')"
