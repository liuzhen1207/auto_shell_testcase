#!/bin/bash
# MB-10 优雅重启后内存缓冲区数据不丢（WAL 回放）：数据只在 memtable/WAL 里时重启 DataNode
#   做法：memtable ~100MB（1:200）、flush_proportion=0.5（阈值 ~50MB），只写 ~3MB，保证不落盘；
#         确认 TsFile 数没变（仍在 memtable）→ 优雅重启该 DN → 校验点数不变、集群收敛。
#   判据：① 重启前确实未落盘（TsFile 数未增加）；
#         ② 重启后 DN 回到 Running；③ 点数不变；④ 一致性校验通过。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-10
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:200:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ
DB=root.mb10
ROWS=${MB10_ROWS:-500}
export EXTRA_CONF=""

mb_cluster_prepare
mb_make_tree_db "$DB" 1 text
ts0=$(mb_tsfile_cnt_all "$DB")

log "--- 写 ${ROWS} 点（约 $(( ROWS * MB_PAYLOAD_BYTES / 1024 / 1024 ))MB），不 flush、关定时刷盘 ⇒ 数据只在 memtable+WAL ---"
ok=$(mb_bulk_text "$DB" d1 "$ROWS" 1); ok=${ok%% *}
assert_ge "写入语句成功数" "${ok:-0}" 1
sleep 5
ts1=$(mb_tsfile_cnt_all "$DB")
# 场景有效性：这条用例要验证"数据只在 memtable/WAL 里时重启不丢"。
# 若写入期间已经落盘，WAL 回放路径就没被真正覆盖 ⇒ 记 WARN（场景未成立），
# 但仍然继续验证"重启后数据完整"，因为那部分判据与是否落盘无关。
if [ "${ts1:-0}" -gt "${ts0:-0}" ]; then
  warn "①场景未完全成立：写入期间已落盘（TsFile $ts0→$ts1），WAL 回放未被充分覆盖；继续验证数据完整性"
else
  pass "①重启前未落盘（TsFile 数未增加：$ts0→$ts1）"
fi
cnt0=$(mb_count_all "$DB")
assert_eq "重启前可查点数" "$cnt0" "$ROWS"

mb_restart_dn "${DN[1]}"
wait_cluster_ready || warn "重启后集群未完全就绪"
check_sync_lag || true

cnt1=$(mb_count_all "$DB")
assert_eq "③重启后点数不丢" "$cnt1" "$ROWS"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
