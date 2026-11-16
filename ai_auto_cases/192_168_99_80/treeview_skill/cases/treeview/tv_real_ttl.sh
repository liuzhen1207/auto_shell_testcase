#!/bin/bash
# ============================================================================
# TV-11 真实数据：WITH TTL（视图 TTL 与树 TTL 取更小值；只影响查询不物理删除）
#   需求 §2.1.1.1（WITH properties：仅 TTL）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_real_ttl_${DATA_CONSENSUS:-$DATA_CONSENSUS}"

DB=db_tv_ttl
P=${TV_DATA_DEV:-root.reactor.system1.techSystem1.DX.HYH_W3.AA5}
T0=${TV_WIN_T0:-2024-11-21T08:00:00}
T1=${TV_WIN_T1:-2024-11-21T08:10:00}
tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }

tv_prologue_keep "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1
S=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$P" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
    | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')

log "--- 1) 无 TTL 基线 ---"
out=$(tqt_db "$DB" "create view base (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "基线视图创建成功" "$(last_msg "$out")" 'successfully'
c0=$(tcol "$(tqt_db "$DB" "select count(*) from base where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
log "  基线窗口行数=$c0"

log "--- 2) 视图 TTL=1 天：该窗口数据（2024-11-21）应被过滤为 0 行 ---"
out=$(tqt_db "$DB" "create view ttl1 (sensor_id STRING TAG, value float field) WITH (ttl=86400000) AS $P.**;")
assert_contains "带 TTL 视图创建成功" "$(last_msg "$out")" 'successfully'
c1=$(tcol "$(tqt_db "$DB" "select count(*) from ttl1 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
log "  TTL=1天 视图窗口行数=$c1（期望 0）"
assert_num_eq "视图 TTL 生效（历史窗口被过滤）" "$c1" "0"

log "--- 3) 树模型侧数据未被物理删除（base 视图仍有数据）---"
c2=$(tcol "$(tqt_db "$DB" "select count(*) from base where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
assert_num_eq "无 TTL 视图仍能查到（TTL 不物理删数据）" "$c2" "$c0"

log "--- 4) 视图 TTL=INF：与无 TTL 等价 ---"
out=$(tqt_db "$DB" "create view ttl_inf (sensor_id STRING TAG, value float field) WITH (ttl='INF') AS $P.**;")
assert_contains "TTL=INF 视图创建成功" "$(last_msg "$out")" 'successfully'
c3=$(tcol "$(tqt_db "$DB" "select count(*) from ttl_inf where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
assert_num_eq "TTL=INF 与基线一致" "$c3" "$c0"

log "--- 5) 改视图 TTL（SET PROPERTIES）后查询随之变化 ---"
out=$(tqt_db "$DB" "alter view base set properties ttl=86400000;")
assert_contains "SET PROPERTIES ttl 成功" "$(last_msg "$out")" 'successfully'
c4=$(tcol "$(tqt_db "$DB" "select count(*) from base where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
log "  base 改 TTL=1天后行数=$c4（期望 0）"
assert_num_eq "SET PROPERTIES 后 TTL 生效" "$c4" "0"
tqt_db "$DB" "alter view base set properties ttl='INF';" >/dev/null 2>&1
c5=$(tcol "$(tqt_db "$DB" "select count(*) from base where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
assert_num_eq "改回 INF 后数据恢复可见" "$c5" "$c0"

log "--- 6) 收尾三件套 ---"
tv_sync_lag 90 || true
tv_replica_consistency "ttl_inf 单传感器 count" "select count(*) from $DB.ttl_inf where sensor_id='$S' and time >= $T0 and time < $T1;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
