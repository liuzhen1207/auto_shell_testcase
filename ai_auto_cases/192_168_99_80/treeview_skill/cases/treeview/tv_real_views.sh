#!/bin/bash
# ============================================================================
# TV-07 真实数据：同一前缀建多个视图（AA5 / AA6）+ 视图间一致性
#   需求 §2.1.2（完整示例：一个前缀可建多张视图）、§2.4（同数据不同列定义）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_real_views_${DATA_CONSENSUS}"

DB=db_tv_rv
P=${TV_DATA_DEV:-root.reactor.system1.techSystem1.DX.HYH_W3.AA5}
T0=${TV_WIN_T0:-2024-11-21T08:00:00}
T1=${TV_WIN_T1:-2024-11-21T09:00:00}

tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
have=$(tree_q "show devices $P.** limit 1;" | grep -ac '^|.*' )
[ "${have:-0}" -le 1 ] && { warn "真实数据未装载 ⇒ 跳过"; tv_case_finish; exit 0; }

tv_prologue_keep "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 1) 同一前缀建两张视图（AA5 / AA6），列定义不同 ---"
out=$(tqt_db "$DB" "create view AA5 (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "AA5 创建成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "create view AA6 (sensor_id STRING TAG, value double field) AS $P.**;")
assert_contains "AA6 创建成功（同前缀、不同类型）" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "show tables;")
# 标识符落库为小写（AA5 → aa5），断言按小写比对
low=$(printf '%s' "$out" | tr 'A-Z' 'a-z')
assert_contains "show tables 含 aa5（视图落库小写）" "$low" 'aa5'
assert_contains "show tables 含 aa6（视图落库小写）" "$low" 'aa6'

log "--- 2) 取一个传感器，两视图与树模型三方一致 ---"
S=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$P" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
    | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')
log "  sensor=$S"
v5=$(tcol "$(tqt_db "$DB" "select count(*) from AA5 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
v6=$(tcol "$(tqt_db "$DB" "select count(*) from AA6 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
t=$(tcol "$(tree_q "select count(*) from $P.$S where time >= $T0 and time < $T1;")" 1)
log "  行数 AA5=$v5 AA6=$v6 树=$t"
assert_num_eq "AA5 与树一致" "$v5" "$t"
assert_num_eq "AA6 与树一致" "$v6" "$t"

a5=$(tcol "$(tqt_db "$DB" "select round(avg(value),4) from AA5 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
a6=$(tcol "$(tqt_db "$DB" "select round(avg(value),4) from AA6 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
at=$(tcol "$(tree_q "select round(avg(value),4) from $P.$S where time >= $T0 and time < $T1;")" 1)
log "  avg AA5=$a5 AA6=$a6 树=$at"
assert_num_eq "AA5 avg 与树一致" "$a5" "$at"
assert_num_eq "AA6 avg 与树一致" "$a6" "$at"

log "--- 3) 两视图 join（同一时间/传感器）---"
out=$(tqt_db "$DB" "select count(*) from AA5 a join AA6 b on a.time=b.time and a.sensor_id=b.sensor_id where a.sensor_id='$S' and a.time >= $T0 and a.time < $T1;")
assert_not_contains "两视图 join 无报错" "$out" 'Exception|ERROR'

log "--- 4) 视图间互不影响（drop AA6 后 AA5 仍可查）---"
tqt_db "$DB" "drop view AA6;" >/dev/null 2>&1
c=$(tcol "$(tqt_db "$DB" "select count(*) from AA5 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
assert_num_eq "drop AA6 后 AA5 行数不变" "$c" "$v5"

log "--- 5) 收尾三件套 ---"
tv_sync_lag 90 || true
tv_replica_consistency "AA5 单传感器 count" "select count(*) from $DB.AA5 where sensor_id='$S' and time >= $T0 and time < $T1;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
