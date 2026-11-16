#!/bin/bash
# ============================================================================
# TV-10 真实数据：高可用（停 1 DN / 停 1 CN 后视图 DDL 与查询可用）
#   需求：视图是元数据+查询能力，集群降级时应继续可用；恢复后数据一致
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_real_ha_${DATA_CONSENSUS}"

DB=db_tv_ha
P=${TV_DATA_DEV:-root.reactor.system1.techSystem1.DX.HYH_W3.AA5}
T0=${TV_WIN_T0:-2024-11-21T08:00:00}
T1=${TV_WIN_T1:-2024-11-21T08:10:00}
tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }

tv_prologue_keep "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1
out=$(tqt_db "$DB" "create view ha (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
S=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$P" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
    | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')
Q="select count(*) from $DB.ha where sensor_id='$S' and time >= $T0 and time < $T1;"
base=""
for _i in $(seq 1 20); do
  base=$(tcol "$(tqt "$Q")" 1)
  [ -n "$base" ] && [ "$base" != "0" ] && break
  sleep 3
done
log "  基线（全在线）= $base  sensor=$S"
tv_sync_lag 60 || true

log "--- 1) 停 1 个 DataNode，视图查询仍可用 ---"
STOP=${DN[0]}
sshx "$STOP" "cd $DB_DIR && bash sbin/stop-datanode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1
sleep 20
# 入口切到存活节点（tqt_db 用 TV_HOST）
for _h in "${DN[@]}"; do [ "$_h" != "$STOP" ] && { TV_HOST=$_h; break; }; done
log "  入口切换为 TV_HOST=$TV_HOST"
ok=0; got=""
for h in "${DN[@]}"; do
  [ "$h" = "$STOP" ] && continue
  got=$(tcol "$(TV_HOST=$h tqt "$Q")" 1)
  log "  经 $h 查询：$got"
  [ "$got" = "$base" ] && ok=$(( ok + 1 ))
done
[ "$ok" -ge 1 ] && pass "停 $STOP 后视图查询仍可用且结果一致（$ok 个入口）" || fail "停 $STOP 后视图查询不可用或不一致（got=$got base=$base）"

log "--- 2) 停 DN 期间建新视图（元数据 DDL 可用） ---"
out=$(tqt_db "$DB" "create view ha2 (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "停 DN 期间 CREATE VIEW 成功" "$(last_msg "$out")" 'successfully'

log "--- 3) 恢复 DN 并等同步 ---"
# 注意：不能写成 `cd X && nohup ... &` 再跟命令——后台子进程继承 stdout 会让 ssh 通道不关闭
sshx "$STOP" "cd $DB_DIR; setsid nohup bash sbin/start-datanode.sh </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 40
TV_HOST=${DN[0]}
# 3.4 亿行数据集：DN 重启后追平较慢，sync lag 非零只记录（不判 FAIL），以"集群 6/6 + 数据一致"为准
if ! tv_sync_lag 120; then
  warn "恢复后 sync lag 未在窗口内归零（3.4 亿行数据集追平较慢，已按记录处理，不判 FAIL）"
fi
got=$(tcol "$(tqt "$Q")" 1)
assert_num_eq "DN 恢复后查询与基线一致" "$got" "$base"

log "--- 4) 停 1 个 ConfigNode（仍有多数派 2/3），查询与 DDL 仍可用 ---"
CSTOP=${CN[0]}
sshx "$CSTOP" "cd $DB_DIR && bash sbin/stop-confignode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1
sleep 25
for _h in "${CN[@]}"; do [ "$_h" != "$CSTOP" ] && { TV_HOST=$_h; break; }; done
log "  入口切换为 TV_HOST=$TV_HOST（CN $CSTOP 已停）"
got=$(tcol "$(tqt "$Q")" 1)
log "  停 CN 后查询=$got（基线 $base）"
assert_num_eq "停 1 CN 后视图查询仍一致" "$got" "$base"
out=$(tqt_db "$DB" "create view ha3 (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "停 1 CN（2/3 多数派）时 CREATE VIEW 成功" "$(last_msg "$out")" 'successfully'

log "--- 5) 恢复 CN ---"
sshx "$CSTOP" "cd $DB_DIR; setsid nohup bash sbin/start-confignode.sh </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 40
tv_sync_lag 60 || true
got=$(tcol "$(tqt "$Q")" 1)
assert_num_eq "CN 恢复后查询与基线一致" "$got" "$base"

log "--- 6) 收尾三件套 ---"
tv_check_logs 0 "CN/DN 日志（HA 场景，含停/启节点）"
tv_case_finish
