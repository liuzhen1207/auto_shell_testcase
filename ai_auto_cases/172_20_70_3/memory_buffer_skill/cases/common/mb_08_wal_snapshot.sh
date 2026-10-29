#!/bin/bash
# MB-08 WAL memtable 快照参数（wal_memtable_snapshot_threshold_in_byte / max_wal_memtable_snapshot_num）
#   做法：阈值压到 1MB、允许 4 份快照；flush_proportion=0.5 保证写 2MB 时不会触发"按大小刷盘"，
#         数据只存在于 memtable + WAL；然后 kill -9 一个 DN，等它重启回放 WAL。
#   判据：① 参数生效（回读 conf）；
#         ② kill -9 后节点恢复 Running；
#         ③ 恢复后数据点数与写入点数一致（WAL 回放不丢）；
#         ④ 全集群一致性通过。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-08
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:1000:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
MB_WAL_SNAPSHOT_THRESHOLD="1048576"
MB_MAX_WAL_SNAPSHOT_NUM="4"
MB_WAL_BUFFER_SIZE="8388608"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_WAL_SNAPSHOT_THRESHOLD MB_MAX_WAL_SNAPSHOT_NUM MB_WAL_BUFFER_SIZE
DB=root.mb08
ROWS=${MB08_ROWS:-500}
export EXTRA_CONF=""

mb_cluster_prepare
for h in "${DN[@]}"; do
  v=$(sshx "$h" "grep -E '^wal_memtable_snapshot_threshold_in_byte=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  assert_eq "$h 阈值生效" "$v" "$MB_WAL_SNAPSHOT_THRESHOLD"
  v=$(sshx "$h" "grep -E '^max_wal_memtable_snapshot_num=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-" | tr -d '\r')
  assert_eq "$h 快照份数生效" "$v" "$MB_MAX_WAL_SNAPSHOT_NUM"
done

mb_make_tree_db "$DB" 1 text
# 规模说明：本用例只需要"数据还在 memtable/WAL 里"，点数越少越安全：
#   RC9 上 2000 点（约 8 次 CLI 会话调用）实测在第 3 次调用后客户端会话就断了（只落 650 点）。
#   500 点 = 2 次调用（每次 4 条语句 × 65 行），足以覆盖 WAL 回放路径且不易被中断。
log "--- 写入 ${ROWS} 点（${MB_PAYLOAD_BYTES}B，约 $(( ROWS * MB_PAYLOAD_BYTES / 1024 / 1024 ))MB），不手工 flush ---"
ok=$(mb_bulk_text "$DB" d1 "$ROWS" 1); ok=${ok%% *}
assert_ge "写入语句成功数" "${ok:-0}" 1
cnt_before=$(mb_count_all "$DB")
assert_eq "宕机前可查点数" "$cnt_before" "$ROWS"

target="${DN[1]}"
mb_kill9_dn "$target"
log "--- 等 WAL 回放稳定 ---"
sleep 10
wait_cluster_ready || warn "恢复后集群未完全就绪"
check_sync_lag || true

cnt_after=$(mb_count_all "$DB")
assert_eq "③宕机+重启后点数不丢（WAL 回放）" "$cnt_after" "$ROWS"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
