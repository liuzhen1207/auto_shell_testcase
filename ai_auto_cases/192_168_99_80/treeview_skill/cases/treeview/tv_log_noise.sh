#!/bin/bash
# ============================================================================
# TV-LOG-01 预期内失败不得产生 ERROR/WARN 噪声（可观测性门禁）
#
#   背景：CREATE VIEW 因「同名测点类型冲突」失败（614，符合需求）属预期内的用户输入错误。
#     存量问题（TDB-894）：CN 对同一失败记 ERROR 并打印完整 response —— RC2 已修复（降 INFO、不带 response）。
#     残留问题：DN 侧仍打 WARN + 完整异常栈（ConfigExecution:223），因 DATA_TYPE_MISMATCH(614)
#       不在 ConfigExecution.userExceptionCodes 里。研发确认随后续 commit 顺带修复，本用例作为回归门禁。
#
#   判据（严格，不做 benign 白名单）：
#     L1 DN 新增 `ConfigExecution:223` WARN 行数 = 0
#     L2 DN 新增异常栈行（`^\s+at org./java.`）= 0
#     L3 CN 新增 `ERROR ... TreeDeviceViewFieldDetectionHandler` = 0（TDB-894 CN 侧回归）
#     L4 CN 新增 `TDeviceViewResp` = 0（不得打印完整 response）
#     L5 场景有效性：客户端必须拿到 614（否则说明没走到"不声明 FIELD 的类型冲突"路径）
#     L6 正向对照：显式声明类型后可正常建视图并查到数据（证明集群/数据正常，非环境问题）
#
#   注意：仅「完全不声明 FIELD」这条路径命中 DN WARN；把 FIELD 列出来但不写类型
#     （`create view ... (t STRING TAG, temp FIELD)`）不会命中，故本用例单独造这种写法。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_log_noise_${DATA_CONSENSUS}"

DB=db_tv_log
LOGD=root.tvlog
CNF=log_confignode_all.log
DNF=log_datanode_all.log
# 只保留基础设施类噪声，不允许把 ConfigExecution 加进来（否则门禁失效）
TV_LOG_BENIGN_EXTRA="License has been given up|Cluster is unactivated"

tv_prologue "$LOGD" "$DB"
# tv_reset_db 只负责删；表模型库要显式建出来，否则 CREATE VIEW 报 701 database is not specified
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

# ---- 日志计数工具 ----------------------------------------------------------
cnt(){ # cnt <host> <file> <extended-regex>
  local h=$1 f=$2 p=$3
  sshx "$h" "grep -acE '$p' $DB_DIR/logs/$f 2>/dev/null" | tr -dc '0-9'
}
sum3(){ # sum3 <file> <regex> → 三节点合计
  local f=$1 p=$2 t=0 h c
  for h in "${DN[@]}"; do
    c=$(cnt "$h" "$f" "$p"); t=$(( t + ${c:-0} ))
  done
  printf '%s' "$t"
}

P_DN_WARN='ConfigExecution:223'
P_DN_STACK='^[[:space:]]+at (org|java)\.'
P_CN_ERR='ERROR.*TreeDeviceViewFieldDetectionHandler'
P_CN_RESP='TDeviceViewResp'

b_dnwarn=$(sum3 "$DNF" "$P_DN_WARN")
b_dnstack=$(sum3 "$DNF" "$P_DN_STACK")
b_cnerr=$(sum3 "$CNF" "$P_CN_ERR")
b_cnresp=$(sum3 "$CNF" "$P_CN_RESP")
log "  日志基线：DN Warn=${b_dnwarn:-0} Stack=${b_dnstack:-0} | CN Err=${b_cnerr:-0} Resp=${b_cnresp:-0}"

log "--- 1) 造树数据：同名测点 s1 在两个设备上类型不同 ---"
out=$(printf '%s\n' \
"create timeseries $LOGD.d1.s1 int32;" \
"create timeseries $LOGD.d2.s1 double;" \
"insert into $LOGD.d1(time,s1) values(1,1);" \
"insert into $LOGD.d2(time,s1) values(1,2);" \
"flush;" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "造树数据无报错" "$out" 'Exception|ERROR'

log "--- 2) CREATE VIEW 不声明 FIELD：类型冲突应报 614（符合需求，非缺陷）---"
out=$(tqt_db "$DB" "create view vlog (dev STRING TAG) AS $LOGD.**;")
assert_err_code "不声明 FIELD 的类型冲突应报 614" "$out" 614

log "--- 3) 等日志落盘后做日志门禁 ---"
sleep 6
a_dnwarn=$(sum3 "$DNF" "$P_DN_WARN")
a_dnstack=$(sum3 "$DNF" "$P_DN_STACK")
a_cnerr=$(sum3 "$CNF" "$P_CN_ERR")
a_cnresp=$(sum3 "$CNF" "$P_CN_RESP")

assert_num_eq "L1 DN 无 ConfigExecution WARN（预期内失败不告警）" "${a_dnwarn:-0}" "${b_dnwarn:-0}"
assert_num_eq "L2 DN 无新增异常栈行" "${a_dnstack:-0}" "${b_dnstack:-0}"
assert_num_eq "L3 CN 无 ERROR（TreeDeviceViewFieldDetectionHandler）" "${a_cnerr:-0}" "${b_cnerr:-0}"
assert_num_eq "L4 CN 不打印完整 response（TDeviceViewResp）" "${a_cnresp:-0}" "${b_cnresp:-0}"

log "--- 4) 正向对照：显式声明类型后视图可建、可查 ---"
out=$(tqt_db "$DB" "create view vok (dev STRING TAG, s1 INT32) AS $LOGD.d1.**;")
assert_contains "显式声明类型可建视图" "$(last_msg "$out")" 'successfully'
n=$(tcol "$(tqt_db "$DB" "select count(*) from vok;")" 1)
assert_eq "视图可查到数据（行数=1）" "$n" "1"

log "--- 5) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "vok count" "select count(*) from $DB.vok;"
tv_check_logs 0 "CN/DN 日志（预期内失败不得产生 ERROR/WARN）"
tv_case_finish
