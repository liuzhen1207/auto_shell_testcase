#!/bin/bash
# ============================================================================
# TB-04 表模型 TTL × 大数据量 × DELETE 数据/设备 × DROP+重建
#   覆盖：
#     1) 批量写入（多行 INSERT，DATA_DEVICES × DATA_ROWS，默认 10×200=2000 行）
#     2) 范围删除：DELETE FROM t WHERE time <= T
#     3) 设备删除：DELETE DEVICES FROM t WHERE dev = 'dK'（返回 num_of_deleted_devices）
#     4) TTL 与 DELETE 叠加：删除后剩余数据按 TTL 过期 + 物理清理证据
#     5) DROP DATABASE 再重建：新库 TTL 继承、新表 TTL 生效
#     6) 收尾三件套：sync lag 归零 / 副本一致性 / CN-DN 日志
# 用法： bash ttl_table_dml.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_table_dml_${DATA_CONSENSUS}"

TDB=dml_db
DATA_DEVICES=${DATA_DEVICES:-10}
DATA_ROWS=${DATA_ROWS:-200}
TTL_MS=${TTL_CASE_MS:-30000}
TTL_WAIT=$(( TTL_MS/1000 + 25 ))
tq(){ sql_lines_table "use $TDB;" "$@"; }
TQ(){ sql_lines_table "$@"; }

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) 批量写入 $DATA_DEVICES 设备 × $DATA_ROWS 行 = $((DATA_DEVICES*DATA_ROWS)) 行 ---"
out=$(TQ "create database $TDB with (ttl=300000);")
assert_contains "建库成功" "$out" "successfully"
out=$(tq "create table t_dml (dev string tag, v double field) with (ttl=300000);")
assert_contains "建表 t_dml 成功" "$out" "successfully"
T0=$(( $(now_ms) - DATA_ROWS*1000 )); t_before=$(now_ms)   # 时间戳落在"过去"
n=$(bulk_table "$TDB" "t_dml" "$DATA_DEVICES" "$DATA_ROWS" "$T0" 1000)
t_after=$(now_ms)
log "  批量写入完成：$n 行，耗时 $((t_after - t_before)) ms（起点 ts=$T0）"
out=$(tq "flush;")
assert_contains "flush 成功" "$out" "successfully"
c=$(scalar "$(TQ "select count(*) from $TDB.t_dml;")")
assert_scalar "写入总行数" "$c" "$((DATA_DEVICES*DATA_ROWS))"
files_before=$(tsfile_counts_all "$TDB")
log "  写入后 TsFile 数(各 DN): $files_before"

log "--- 2) 范围删除：删除全部设备最早 $(($DATA_ROWS/2)) 行 ---"
DEL_T=$(( T0 + ($DATA_ROWS/2 - 1) * 1000 ))
out=$(tq "delete from t_dml where time <= $DEL_T;")
assert_contains "范围删除成功" "$out" "successfully"
wait_scalar_table "select count(*) from $TDB.t_dml;" "$((DATA_DEVICES*DATA_ROWS/2))" 120 "删除后总行数"
wait_scalar_table "select count(*) from $TDB.t_dml where time <= $DEL_T;" "0" 60 "被删时间段应查不到"

log "--- 3) 设备删除：DELETE DEVICES FROM t_dml WHERE dev='d${DATA_DEVICES}' ---"
VICTIM="d${DATA_DEVICES}"
out=$(tq "delete devices from t_dml where dev = '$VICTIM';")
assert_contains "DELETE DEVICES 成功" "$out" "successfully"
nd=$(scalar "$out"); nd=${nd:-0}
assert_scalar "删除设备数" "$nd" "1"
wait_scalar_table "select count(*) from $TDB.t_dml;" "$(((DATA_DEVICES-1)*DATA_ROWS/2))" 120 "删设备后总行数"
wait_scalar_table "select count(*) from $TDB.t_dml where dev = '$VICTIM';" "0" 60 "被删设备数据应查不到"
out=$(tq "insert into t_dml (time, dev, v) values ($(now_ms), '$VICTIM', 1);")
assert_contains "被删设备可重新写入" "$out" "successfully"

log "--- 4) 调小表 TTL=$TTL_MS，等过期并验证物理清理 ---"
out=$(tq "alter table t_dml set properties ttl=$TTL_MS;")
assert_contains "alter table ttl 成功" "$out" "successfully"
tq "flush;" >/dev/null
c=$(scalar "$(TQ "select count(*) from $TDB.t_dml;")")
log "  设 TTL 后立即查询行数=$c（含刚写入的那条）"
base_settle=$(sum_over settle_line_cnt); base_sel=$(sum_over ttl_selected_positive_cnt)
sleep "$TTL_WAIT"
c=$(scalar "$(TQ "select count(*) from $TDB.t_dml;")")
assert_scalar "过期后总行数" "$c" "0"
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); cleaned=0
while (( $(date +%s) < deadline )); do
  cur_settle=$(sum_over settle_line_cnt); cur_sel=$(sum_over ttl_selected_positive_cnt); cur=$(tsfile_counts_all "$TDB")
  log "  等清理: selectedAllOutdated=$cur_sel(+$((cur_sel-base_sel))) settleDeleted=$cur_settle(+$((cur_settle-base_settle))) tsFiles=$cur"
  if [ "$cur_settle" -gt "$base_settle" ] || [ "$cur_sel" -gt "$base_sel" ] || [ "$cur" != "$files_before" ]; then cleaned=1; break; fi
  sleep 5
done
[ "$cleaned" = "1" ] && pass "过期清理已发生：selectedAllOutdated +$((cur_sel-base_sel))，settleDeleted +$((cur_settle-base_settle))，tsFiles $files_before -> $cur" \
                     || fail "等 ${CLEANUP_WAIT_SEC}s 未见清理动作（tsFiles=$cur）"

log "--- 5) DROP DATABASE 再重建：新库 TTL 继承 + 新表 TTL 生效 ---"
out=$(TQ "drop database $TDB;")
assert_contains "drop database 成功" "$out" "successfully"
out=$(TQ "create database $TDB with (ttl=$TTL_MS);")
assert_contains "重建库(带 ttl)成功" "$out" "successfully"
out=$(TQ "select database, \"ttl(ms)\" from information_schema.databases;")
assert_eq "重建后库 TTL" "$(row_col "$out" "$TDB" 2)" "$TTL_MS"
out=$(tq "create table t_re (dev string tag, v double field);")
assert_contains "重建后建表成功" "$out" "successfully"
out=$(tq "show tables;")
assert_eq "新表继承重建后的库 TTL" "$(table_ttl "$out" t_re)" "$TTL_MS"
out=$(tq "insert into t_re (time, dev, v) values ($(now_ms), 'd1', 1);")
assert_contains "重建后写入成功" "$out" "successfully"
tq "flush;" >/dev/null
c=$(scalar "$(TQ "select count(*) from $TDB.t_re;")")
assert_scalar "重建后新数据立即可见" "$c" "1"
sleep "$TTL_WAIT"
c=$(scalar "$(TQ "select count(*) from $TDB.t_re;")")
assert_scalar "重建后新数据到期不可见" "$c" "0"

log "--- 6) 收尾三件套 ---"
post_checks "select count(*) from $TDB.t_re;" table
ttl_case_finish "" table ""
