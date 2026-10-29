#!/bin/bash
# MB-04 定时刷盘（顺序空间）：enable_timed_flush_seq_memtable + interval + check_interval
#   做法：把 flush_proportion 调到 0.5（阈值 ≈10MB）但只写 <1MB，保证"按大小"不会刷；
#         seq_memtable_flush_interval_in_ms=15000 / check=5000 ⇒ 靠定时器落盘。
#   判据：① 不手工 flush 也在窗口内产生新 TsFile；② 数据点数不变；
#         ③ 把 enable_timed_flush_seq_memtable 关掉后（对照组）同样窗口内不产生新 TsFile。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-04
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="${MB_MEM_PROPORTION:-1:1000:1:1:1:1}"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="true"
MB_SEQ_FLUSH_INTERVAL="15000"
MB_SEQ_FLUSH_CHECK="5000"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_SEQ_FLUSH_INTERVAL MB_SEQ_FLUSH_CHECK
DB=root.mb04
ROWS=${MB04_ROWS:-600}
TIMED_WIN=${MB04_WIN:-150}
export EXTRA_CONF=""

# 等"定时刷盘"窗口：轮询 tsfile 数是否增加
wait_timed_flush(){ local db=$1 t0=$2 win=$3 deadline=$(( $(date +%s) + $3 )) now
  while (( $(date +%s) < deadline )); do
    now=$(mb_tsfile_cnt_all "$db")
    log "  定时刷盘观察: tsfile=$now (基线=$t0)"
    [ "${now:-0}" -gt "${t0:-0}" ] && return 0
    sleep 10
  done
  return 1
}

mb_cluster_prepare
mb_make_tree_db "$DB" 1 text

ts0=$(mb_tsfile_cnt_all "$DB")
log "--- 阶段 A：定时刷盘开启，写入 ${ROWS} 点后不手工 flush ---"
mb_bulk_text "$DB" d1 "$ROWS" 1 >/dev/null
if wait_timed_flush "$DB" "$ts0" "$TIMED_WIN"; then pass "阶段A：定时刷盘触发（tsfile 增加）"
else fail "阶段A：${TIMED_WIN}s 内定时刷盘未触发"; fi
assert_eq "阶段A 数据点数" "$(mb_count_all "$DB")" "$ROWS"

log "--- 阶段 B（对照组）：关闭定时刷盘，同样窗口内不应产生新 TsFile ---"
sq "set configuration 'enable_timed_flush_seq_memtable'='false';" >/dev/null 2>&1
sleep 3
ts1=$(mb_tsfile_cnt_all "$DB")
mb_bulk_text "$DB" d1 "$ROWS" 2 >/dev/null
sleep "$TIMED_WIN"
ts2=$(mb_tsfile_cnt_all "$DB")
log "  阶段B tsfile: $ts1 -> $ts2"
assert_eq "阶段B 关闭定时刷盘后无新 TsFile" "$ts2" "$ts1"
assert_eq "阶段B 数据点数（仍在 memtable 里，可查）" "$(mb_count_all "$DB")" "$(( ROWS * 2 ))"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
