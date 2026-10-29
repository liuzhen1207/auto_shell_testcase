#!/bin/bash
# MB-13 高可用：写入压力下停 1 个 DataNode（DataRegion 2 副本），写入不中断、数据不丢
#   做法：并发写入的同时停掉 DN[4]（172.20.70.30），写入继续；随后把节点起回来，
#         等 syncLag 归零，再按"逐个停 DN"做全量副本一致性。
#   判据：① 停节点期间写入仍有成功语句、查询无异常；
#         ② 停节点期间集群仍有 ${#DN[@]}-1 个 DN 在线；
#         ③ 节点恢复 Running；④ 点数 == 成功语句数 × 每语句行数；⑤ 一致性通过。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-13
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:500:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION
DB=root.mb13
ROWS=${MB13_ROWS:-3000}
TARGET="${DN[4]:-${DN[${#DN[@]}-1]}}"
export EXTRA_CONF=""

mb_cluster_prepare
mb_make_tree_db "$DB" 2 int64

log "--- 后台写入 + 中途停 DN $TARGET ---"
( mb_bulk_int "$DB" d1 "$ROWS" 1 >/tmp/mb13_a.res 2>&1 ) &
p1=$!
sleep 8
log "  --- 停 DataNode $TARGET ---"
sshx "$TARGET" "sudo $DB_DIR/sbin/stop-datanode.sh >/dev/null 2>&1 || true; sudo pkill -9 -f 'com\.timecho\.iotdb\.DataNode' >/dev/null 2>&1 || true"
wait_dn_state "$TARGET" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $TARGET 超时"
running=$(sq 'show cluster;' 2>/dev/null | grep -E '^\|.*DataNode.*Running' | wc -l | tr -d ' ')
assert_eq "②停节点期间在线 DN 数" "$running" "$(( ${#DN[@]} - 1 ))"

( mb_bulk_int "$DB" d2 "$ROWS" 1 >/tmp/mb13_b.res 2>&1 ) &
p2=$!
wait $p1 $p2
ok1=$(awk '{print $1}' /tmp/mb13_a.res); ok2=$(awk '{print $1}' /tmp/mb13_b.res)
ok_total=$(( ${ok1:-0} + ${ok2:-0} ))
log "  写入结果: d1 ok=${ok1:-0} / d2 ok=${ok2:-0}"
assert_ge "①停节点期间写入仍有成功语句" "${ok2:-0}" 1

q=$(sq "select s1 from $DB.d1 order by time;" 2>&1)
assert_not_contains "停节点期间查询无异常" "$q" 'Exception|ERROR'

log "  --- 恢复 DataNode $TARGET ---"
sshx "$TARGET" "source /etc/profile; nohup sudo $DB_DIR/sbin/start-datanode.sh >/dev/null 2>&1 &"
wait_dn_state "$TARGET" running "$RESTART_WAIT_SEC" || fail "③DataNode $TARGET 未恢复 Running"
wait_cluster_ready || warn "恢复后集群未完全就绪"
sq 'flush;' >/dev/null 2>&1
sleep 5

tot=0
tot=$(mb_count_all "$DB")
log "  实际点数=$tot 期望=$(( ok_total * MB_ROWS_PER_STMT ))"
assert_eq "④点数 == 成功语句数 × 每语句行数" "$tot" "$(( ok_total * MB_ROWS_PER_STMT ))"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
