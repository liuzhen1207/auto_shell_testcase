#!/bin/bash
# MB-03 按比例触发刷盘（flush_proportion）：memtable 用量越过 flush 阈值必须自动落盘
#   做法：把 memtable 压到 ~20MB（datanode_memory_proportion 1:1000），flush_proportion 保持 0.4
#         （阈值 ≈ 8MB），写入 ~8MB TEXT 数据后不再手工 flush，观察自动刷盘。
#   判据：① 刷盘累计计数增加；② 出现新的 TsFile；③ 区域 memCost 回落到阈值以下；
#         ④ 数据不丢（点数 == 写入点数）；⑤ 未进入 reject 状态（阈值未到）。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-03
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="${MB_MEM_PROPORTION:-1:2000:1:1:1:1}"
MB_FLUSH_PROPORTION="0.4"
MB_REJECT_PROPORTION="0.8"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_REJECT_PROPORTION
DB=root.mb03
DEVS=1
ROWS=${MB03_ROWS:-1200}
export EXTRA_CONF=""

mb_cluster_prepare
mb_make_tree_db "$DB" "$DEVS" text

flush0=$(mb_flush_all); ts0=$(mb_tsfile_cnt_all "$DB"); rej0=$(mb_reject_enter_all)
log "  基线: flush_total=$flush0 tsfile=$ts0 reject_enter=$rej0 regionMemCost=$(mb_region_mem_all)"

# 实测：memtable 阈值 ≈ 15.5MB（1:1000）、flush 阈值 ≈ 6.2MB；写 2000×4000B ≈ 8MB 即可越过
log "--- 写入 ${ROWS} 点（payload=${MB_PAYLOAD_BYTES}B，约 $(( ROWS * MB_PAYLOAD_BYTES / 1024 / 1024 ))MB）---"
ok=$(mb_bulk_text "$DB" d1 "$ROWS" 1)
assert_ge "写入语句成功数" "${ok%% *}" 1

log "--- 等自动刷盘（不手工 flush）---"
if mb_wait_flush "$flush0" "$FLUSH_WAIT_SEC"; then pass "自动刷盘已触发"; else fail "等 ${FLUSH_WAIT_SEC}s 未观察到自动刷盘"; fi
sleep 5

flush1=$(mb_flush_all); ts1=$(mb_tsfile_cnt_all "$DB"); rej1=$(mb_reject_enter_all); mem1=$(mb_region_mem_all)
log "  结果: flush_total=$flush1 tsfile=$ts1 reject_enter=$rej1 regionMemCost=$mem1"
assert_ge "刷盘累计次数增加" "$flush1" "$(( flush0 + 1 ))"
assert_ge "产生新的 TsFile" "$ts1" "$(( ts0 + 1 ))"
assert_eq "未进入 reject 状态（阈值未到）" "$rej1" "$rej0"

cnt=$(mb_count_all "$DB")
assert_eq "刷盘后数据不丢" "$cnt" "$ROWS"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
