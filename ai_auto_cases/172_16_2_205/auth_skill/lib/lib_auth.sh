#!/bin/bash
# Shared helpers for the identity-authentication suite (v20121rc12 / c05111d).
# Sourced by suite_auth.sh before the case files.
NEW=${NEW:-v20121rc12_1027_c05111d}
CLI=${CLI:-/data2/iotdb/$NEW/sbin/start-cli.sh}
PW=${PW:-TimechoDB@2021}
HOST=${HOST:-172.16.2.2}
DN_LIST=${DN_LIST:-"172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"}
CN_LIST=${CN_LIST:-"172.16.2.26 172.16.2.27 172.16.2.28"}

CASE_FAILS=0
CASE_MSGS=""

fail() { CASE_FAILS=$((CASE_FAILS+1)); CASE_MSGS="$CASE_MSGS [FAIL] $* ;"; echo "  [FAIL] $*"; }
ok()   { echo "  [ok] $*"; }

# 模式：normal（root 全权）| separation（三权分立：sys_admin / security_admin / audit_admin）
MODE=${MODE:-normal}
if [ "$MODE" = "separation" ]; then
  SYSADMIN=${SYSADMIN:-sys_admin}; SECADMIN=${SECADMIN:-security_admin}; AUDITADMIN=${AUDITADMIN:-audit_admin}
else
  SYSADMIN=${SYSADMIN:-root}; SECADMIN=${SECADMIN:-root}; AUDITADMIN=${AUDITADMIN:-root}
fi

# 系统/数据管理员（普通模式=root；三权分立=sys_admin）
T()  { $CLI -h "$HOST" -p 6667 -u "$SYSADMIN" -pw "$PW" -sql_dialect tree -e "$1" 2>&1; }
# 安全管理员（用户/角色/权限）
TS() { $CLI -h "$HOST" -p 6667 -u "$SECADMIN" -pw "$PW" -sql_dialect tree -e "$1" 2>&1; }
# 审计管理员
TA() { $CLI -h "$HOST" -p 6667 -u "$AUDITADMIN" -pw "$PW" -sql_dialect tree -e "$1" 2>&1; }
# login as a user and run one statement
L() { local u=$1 p=$2 sql=${3:-"show databases"}; $CLI -h "$HOST" -p 6667 -u "$u" -pw "$p" -e "$sql" 2>&1; }

assert_ok()      { echo "$1" | grep -qE "Msg: The statement is executed successfully|Total line number|^\+" || fail "$2: 预期成功，实际 $(echo "$1" | head -1)"; }
assert_err()     { echo "$1" | grep -qE "Msg:|Error:|ERROR|Exception" || fail "$2: 预期失败，实际 $(echo "$1" | head -1)"; }
assert_code()    { echo "$1" | grep -q "$2" || fail "$3: 预期错误码 $2，实际 $(echo "$1" | head -1)"; }
assert_contains(){ echo "$1" | grep -q "$2" || fail "$3: 预期包含 '$2'，实际 $(echo "$1" | head -1)"; }
assert_not_contains(){ echo "$1" | grep -q "$2" && fail "$3: 不应包含 '$2'"; return 0; }

# log scanning
log_files() {
  local ip=$1
  echo "/data1/iotdb/$NEW/logs/log_datanode_all.log"
}

log_size() { local ip=$1 f; f=$(log_files "$ip"); ssh -o StrictHostKeyChecking=no root@$ip "stat -c%s $f 2>/dev/null || echo 0" 2>/dev/null; }

log_mark_all() {
  MARKS=""
  for ip in $DN_LIST; do
    MARKS="$MARKS $ip:$(log_size $ip)"
  done
}

# echo "ERROR_COUNT BENIGN_COUNT"
log_delta() {
  local ip=$1 mark=$2 f out total benign
  f=$(log_files "$ip")
  out=$(ssh -o StrictHostKeyChecking=no root@$ip "tail -c +$((mark+1)) $f 2>/dev/null" 2>/dev/null)
  total=$(echo "$out" | grep -c " ERROR " )
  benign=$(echo "$out" | grep " ERROR " | grep -cE 'DataNodeAuthUtils|Fail to check password expiration|GrpcLogAppender|Failed requestVote|Failed appendEntries|ServerNotReady|LeaderElection|Connection refused|Connection reset|is interrupted|TimeoutException')
  echo "$total $benign"
}

wait_running() {
  local want=${1:-8} i n
  for i in $(seq 1 60); do
    n=$(T "show cluster;" 2>/dev/null | grep -c "Running")
    [ "$n" -ge "$want" ] && return 0
    sleep 5
  done
  return 1
}

restart_dn() {
  local ip=$1
  ssh -o StrictHostKeyChecking=no root@$ip "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh >/dev/null 2>&1; sleep 3; pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 3" 2>/dev/null
  ssh -o StrictHostKeyChecking=no root@$ip "setsid /data1/iotdb/$NEW/sbin/start-datanode.sh >> /tmp/dn_restart.log 2>&1 < /dev/null &" 2>/dev/null
  sleep 12
  wait_running 8
}
