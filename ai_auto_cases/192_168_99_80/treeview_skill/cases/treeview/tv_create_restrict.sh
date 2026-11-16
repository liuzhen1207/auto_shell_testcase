#!/bin/bash
# ============================================================================
# TV-03 RESTRICT 与设备层级匹配（需求 §2.1.1.3）
#   TAG 数 = 1：无 RESTRICT 时包含层级 <=1 的设备；RESTRICT 时只含层级 ==1
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_create_restrict_${DATA_CONSENSUS}"
TV_LOG_BENIGN_EXTRA="Failures happened during running ConfigExecution|CreateTable"

DB=db_tv_res
LOGD=root.tvres
tv_prologue "$LOGD" "$DB"

log "--- 1) 造三层设备：lvl1 / lvl2 / lvl3 ---"
out=$(printf '%s\n' \
"create database $LOGD;" \
"create timeseries $LOGD.lvl1.m float;" \
"create timeseries $LOGD.lvl2.sub.m float;" \
"create timeseries $LOGD.lvl3.sub.deep.m float;" \
"insert into $LOGD.lvl1(time,m) values(1000,1.0);" \
"insert into $LOGD.lvl2.sub(time,m) values(1000,2.0);" \
"insert into $LOGD.lvl3.sub.deep(time,m) values(1000,3.0);" \
"flush;" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "树数据无报错" "$out" 'Exception|ERROR'
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 2) 无 RESTRICT（tag=1）：应包含层级<=1 的设备（lvl1）---"
out=$(tqt_db "$DB" "create view vlen (dev STRING TAG, m float) AS $LOGD.**;")
assert_contains "vlen 创建成功" "$(last_msg "$out")" 'successfully'
n=$(tcol "$(tqt_db "$DB" "select count(*) from vlen;")" 1)
assert_eq "无 RESTRICT 只含 lvl1（1 行）" "$n" "1"

log "--- 3) 有 RESTRICT（tag=1）：只含层级==1 的设备（lvl1）---"
out=$(tqt_db "$DB" "create view vlen_r (dev STRING TAG, m float) RESTRICT AS $LOGD.**;")
assert_contains "vlen_r 创建成功" "$(last_msg "$out")" 'successfully'
n=$(tcol "$(tqt_db "$DB" "select count(*) from vlen_r;")" 1)
assert_eq "RESTRICT 只含 lvl1（1 行）" "$n" "1"

log "--- 4) tag=0 边界：无 TAG 列（仅 FIELD），RESTRICT 下应只含层级==0 ---"
out=$(tqt_db "$DB" "create view vzero (m float) RESTRICT AS $LOGD.**;")
assert_contains "tag=0 + RESTRICT 可创建（产品允许？实测成功）" "$(last_msg "$out")" 'successfully'
n=$(tcol "$(tqt_db "$DB" "select count(*) from vzero;")" 1)
assert_eq "tag=0 + RESTRICT 视图为空（层级==0 无设备）" "$n" "0"

log "--- 5) 覆盖数据库根设备（前缀为 root.**，tag=3 可覆盖 lvl3）---"
out=$(tqt_db "$DB" "create view vdeep (a STRING TAG, b STRING TAG, c STRING TAG, m float) AS $LOGD.**;")
assert_contains "vdeep 创建成功" "$(last_msg "$out")" 'successfully'
n=$(tcol "$(tqt_db "$DB" "select count(*) from vdeep;")" 1)
log "  vdeep 行数=$n（tag=3 时层级<=3 的设备都应包含，实测作为记录）"

log "--- 6) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "vlen count" "select count(*), sum(m) from $DB.vlen;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
