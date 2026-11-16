#!/bin/bash
# ============================================================================
# TV-08 真实数据：查询能力与树模型对照（需求 §2.4 / §3）
#   投影/where/order/limit、聚合、按 tag 分组、子查询、聚合与树等价性（时间窗限定，避免 719）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_real_query_${DATA_CONSENSUS}"

DB=db_tv_rq
P=${TV_DATA_DEV:-root.reactor.system1.techSystem1.DX.HYH_W3.AA5}
T0=${TV_WIN_T0:-2024-11-21T08:00:00}
T1=${TV_WIN_T1:-2024-11-21T09:00:00}
tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }

tv_prologue_keep "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1
out=$(tqt_db "$DB" "create view rq (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'

S=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$P" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
    | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')
log "  sensor=$S  窗口=[$T0, $T1)"

log "--- 1) 投影 + where + order/limit ---"
out=$(tqt_db "$DB" "select time, value from rq where sensor_id='$S' and time >= $T0 and time < $T1 order by time limit 5;")
assert_not_contains "投影/order/limit 无报错" "$out" 'Exception|ERROR'
rows=$(printf '%s' "$out" | table_rows | wc -l | tr -d ' ')
log "  返回数据行数=$rows"
[ "${rows:-0}" -ge 1 ] && pass "投影返回了数据行（$rows）" || fail "投影没有返回数据行"

log "--- 2) 聚合（count / avg / min / max）与树模型对照 ---"
for agg in count avg min max; do
  if [ "$agg" = count ]; then sqlv="count(*)"; sqlt="count(*)"; else sqlv="$agg(value)"; sqlt="$agg(value)"; fi
  v=$(tcol "$(tqt_db "$DB" "select round($sqlv,4) from rq where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
  t=$(tcol "$(tree_q "select round($sqlt,4) from $P.$S where time >= $T0 and time < $T1;")" 1)
  log "  $agg: 视图=$v 树=$t"
  assert_num_eq "$agg(value) 与树一致" "$v" "$t"
done

log "--- 3) 按 tag 分组（前 3 个传感器）---"
out=$(tqt_db "$DB" "select sensor_id, count(*) from rq where time >= $T0 and time < $T1 group by sensor_id order by sensor_id limit 3;")
assert_not_contains "group by sensor_id 无报错" "$out" 'Exception|ERROR'
log "  $(printf '%s' "$out" | grep -a '^|' | tail -3 | tr '\n' ' ' | cut -c1-220)"

log "--- 4) 子查询 / 时间过滤表达式 ---"
out=$(tqt_db "$DB" "select count(*) from (select sensor_id, value from rq where time >= $T0 and time < $T1 and value > 0) t;")
assert_not_contains "子查询无报错" "$out" 'Exception|ERROR'

log "--- 5) 与树模型 where value>0 对照 ---"
v=$(tcol "$(tqt_db "$DB" "select count(*) from rq where sensor_id='$S' and time >= $T0 and time < $T1 and value > 0;")" 1)
t=$(tcol "$(tree_q "select count(*) from $P.$S where time >= $T0 and time < $T1 and value > 0;")" 1)
assert_num_eq "where value>0 行数与树一致" "$v" "$t"

log "--- 6) 收尾三件套 ---"
tv_sync_lag 90 || true
tv_replica_consistency "rq 单传感器 count" "select count(*) from $DB.rq where sensor_id='$S' and time >= $T0 and time < $T1;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
