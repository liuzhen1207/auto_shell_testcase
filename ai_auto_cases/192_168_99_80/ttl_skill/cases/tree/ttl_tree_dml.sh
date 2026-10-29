#!/bin/bash
# ============================================================================
# TT-03 树模型 TTL × 大数据量 × DELETE 数据/元数据 × DROP+重建
#   覆盖：
#     1) 批量写入（多值 INSERT，DATA_DEVICES × DATA_ROWS，默认 10×200=2000 点）
#     2) 范围删除：DELETE FROM <device> WHERE time <= T（数据删除正确性）
#     3) 元数据删除：DELETE TIMESERIES <device>.**（删设备数据 + 元数据）
#     4) TTL 与 DELETE 叠加：删除后再按 TTL 过期，查询与清理都要正确
#     5) DROP DATABASE 再重建：TTL 规则是否保留、重建后 TTL 是否对新数据生效
#     6) 收尾三件套：sync lag 归零 / 副本一致性 / CN-DN 日志
# 用法： bash ttl_tree_dml.sh [--consensus ...] [--framework 0|1]
# 规模可用环境变量调：DATA_DEVICES / DATA_ROWS / TTL_CASE_MS
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_tree_dml_${DATA_CONSENSUS}"

DB=root.dml_t
DATA_DEVICES=${DATA_DEVICES:-10}
DATA_ROWS=${DATA_ROWS:-200}
TTL_MS=${TTL_CASE_MS:-30000}
TTL_WAIT=$(( TTL_MS/1000 + 25 ))

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) 批量写入 $DATA_DEVICES 设备 × $DATA_ROWS 行 = $((DATA_DEVICES*DATA_ROWS)) 点（多值 INSERT） ---"
sq "create database $DB;" >/dev/null
T0=$(( $(now_ms) - DATA_ROWS*1000 ))   # 时间戳落在"过去"，便于后续按 TTL 过期
t_before=$(now_ms)
n=$(bulk_tree "$DB" "d" "$DATA_DEVICES" "$DATA_ROWS" "$T0" 1000)
t_after=$(now_ms)
log "  批量写入完成：$n 点，耗时 $((t_after - t_before)) ms（起点 ts=$T0）"
out=$(sq "flush;")
assert_contains "flush 成功" "$out" "successfully"
c1=$(scalar "$(sq "select count(*) from $DB.d1;")")
cN=$(scalar "$(sq "select count(*) from $DB.d${DATA_DEVICES};")")
assert_scalar "d1 写入行数" "$c1" "$DATA_ROWS"
assert_scalar "d${DATA_DEVICES} 写入行数" "$cN" "$DATA_ROWS"
files_before=$(tsfile_counts_all "$DB")
log "  写入后 TsFile 数(各 DN): $files_before"

log "--- 2) 范围删除：删除每设备最早 $(($DATA_ROWS/2)) 行（time <= T0+$((($DATA_ROWS/2-1)*1000))) ---"
DEL_T=$(( T0 + ($DATA_ROWS/2 - 1) * 1000 ))
out=$(sq "delete from $DB.d1.** where time <= $DEL_T;")
assert_contains "范围删除成功" "$out" "successfully"
wait_scalar_tree "select count(*) from $DB.d1;" "$(($DATA_ROWS/2))" 90 "d1 删除后剩余行数"
wait_scalar_tree "select count(*) from $DB.d1 where time <= $DEL_T;" "0" 90 "被删时间段应查不到"
wait_scalar_tree "select count(*) from $DB.d1 where time > $DEL_T;" "$(($DATA_ROWS/2))" 90 "保留时间段行数"

log "--- 3) 元数据删除：DELETE TIMESERIES $DB.d${DATA_DEVICES}.**（删设备数据+元数据） ---"
sq "delete timeseries $DB.d${DATA_DEVICES}.**;" >/dev/null 2>&1
out=$(sq "show devices $DB.**;")
dev_tail=$(printf '%s\n' "$out" | grep -c "$DB.d${DATA_DEVICES}")
assert_eq "被删设备不应再出现在 show devices" "$dev_tail" "0"
c_del_dev=$(scalar "$(sq "select count(*) from $DB.d${DATA_DEVICES};")"); c_del_dev=${c_del_dev:-0}
assert_scalar "被删设备查询行数" "$c_del_dev" "0"
wait_scalar_tree "select count(*) from $DB.d1;" "$(($DATA_ROWS/2))" 60 "其他设备不受影响"

log "--- 4) 先设大 TTL 验证数据可见，再调小 TTL 验证过期与清理 ---"
TNEW=$(now_ms)
sq "insert into $DB.d1(time,s1) values($TNEW, 999);" >/dev/null
sq "set ttl to $DB 300000;" >/dev/null
sq "flush;" >/dev/null
base_settle=$(sum_over settle_line_cnt); base_sel=$(sum_over ttl_selected_positive_cnt)
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "大 TTL 下 d1 行数(全部可见)" "$c" "$((DATA_ROWS/2 + 1))"
sq "set ttl to $DB $TTL_MS;" >/dev/null
log "  等 ${TTL_WAIT}s 让旧数据过期（新写入那条也应过期）..."
sleep "$TTL_WAIT"
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "过期后 d1 行数" "$c" "0"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0
while (( $(date +%s) < deadline )); do
  cur_settle=$(sum_over settle_line_cnt); cur_sel=$(sum_over ttl_selected_positive_cnt); cur=$(tsfile_counts_all "$DB")
  log "  等清理: selectedAllOutdated=$cur_sel(+$((cur_sel-base_sel))) settleDeleted=$cur_settle(+$((cur_settle-base_settle))) tsFiles=$cur"
  if [ "$cur_settle" -gt "$base_settle" ] || [ "$cur_sel" -gt "$base_sel" ] || [ "$cur" != "$files_before" ]; then cleaned=1; break; fi
  sleep 5
done
[ "$cleaned" = "1" ] && pass "过期清理已发生：selectedAllOutdated +$((cur_sel-base_sel))，settleDeleted +$((cur_settle-base_settle))，tsFiles $files_before -> $cur" \
                     || fail "等 ${CLEANUP_WAIT_SEC}s 未见清理动作（tsFiles=$cur）"

log "--- 5) DROP DATABASE 再重建：确认 TTL 规则保留、重建后对新数据生效 ---"
out=$(sq "show all ttl;")
assert_eq "drop 前规则存在" "$(rule_ttl "$out" "$DB")" "$TTL_MS"
sq "drop database $DB;" >/dev/null 2>&1
out=$(sq "show all ttl;")
assert_eq "drop database 后 TTL 规则仍保留" "$(rule_ttl "$out" "$DB")" "$TTL_MS"
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=int64;" >/dev/null
TRE=$(now_ms)
sq "insert into $DB.d1(time,s1) values($TRE, 1);" >/dev/null
sq "flush;" >/dev/null
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "重建后新数据立即可见" "$c" "1"
out=$(sq "show devices $DB.**;")
assert_eq "重建后设备沿用原 TTL 规则" "$(device_ttl "$out" "$DB.d1")" "$TTL_MS"
sleep "$TTL_WAIT"
c=$(scalar "$(sq "select count(*) from $DB.d1;")")
assert_scalar "重建后新数据到期不可见" "$c" "0"

log "--- 6) 收尾三件套 ---"
post_checks "select count(*) from $DB.d1;" tree
ttl_case_finish "" tree ""
