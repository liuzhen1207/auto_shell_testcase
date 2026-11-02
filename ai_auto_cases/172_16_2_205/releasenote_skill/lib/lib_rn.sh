#!/bin/bash
# ============================================================================
# releasenote_skill 套件公共库
#   T()  tree 方言 SQL（root）；Q() table 方言；L() 指定用户登录
#   ok()/fail() 断言；start_dn()/wait_running() 节点操作
# ============================================================================
: "${NEW:=v20131rc1_1030_ab6d3de}"
: "${CLI:=/data2/iotdb/$NEW/sbin/start-cli.sh}"
: "${HOST:=172.16.2.2}"
: "${PW:=TimechoDB@2021}"
: "${CN_LIST:=172.16.2.26 172.16.2.27 172.16.2.28}"
: "${DN_LIST:=172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6}"

T()  { timeout 90 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect tree  -e "$1" 2>&1; }
Q()  { timeout 90 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect table -e "$1" 2>&1; }
L()  { timeout 90 $CLI -h "$HOST" -p 6667 -u "$1"  -pw "$2" -sql_dialect tree  -e "$3" 2>&1; }

CASE_FAILS=0
CASE_MSGS=""
ok()   { echo "  [ok] $*"; }
fail() { CASE_FAILS=$((CASE_FAILS+1)); CASE_MSGS="${CASE_MSGS}[FAIL] $* ; "; echo "  [FAIL] $*"; }

assert_ok()       { if echo "$1" | grep -qiE 'Exception|ERROR|timeout|超时'; then fail "$2: 预期成功，实际 $(echo "$1" | head -1 | cut -c1-120)"; else ok "$2"; fi; }
assert_contains() { if echo "$1" | grep -q "$2"; then ok "$3"; else fail "$3: 预期包含 '$2'"; fi; }
assert_not_contains() { if echo "$1" | grep -qi "$2"; then fail "$3: 不应出现 '$2'"; else ok "$3"; fi; }

# 启动 DN（setsid，避免 ssh 会话退出把进程带走），并等待进程存活
start_dn() {
  local ip=$1 attempt n
  for attempt in 1 2 3; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" != "0" ] && return 0
    ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd $DN_DIR; setsid $DN_DIR/sbin/start-datanode.sh > $DN_DIR/start_dn.log 2>&1 < /dev/null &" 2>/dev/null
    sleep 20
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.DataNode'" 2>/dev/null)
    [ "${n:-0}" != "0" ] && return 0
    echo "  start_dn $ip attempt $attempt failed, retrying"
    sleep 5
  done
  echo "  start_dn $ip FAILED after 3 attempts"
  return 1
}

wait_running() {
  local want=${1:-300} i n
  for i in $(seq 1 $((want / 5))); do
    n=$(T "show cluster;" 2>/dev/null | grep -c 'Running')
    [ "${n:-0}" -ge 8 ] && return 0
    sleep 5
  done
  return 1
}

# 毫秒计时执行 SQL：run_timed "sql" -> 输出 SQL 结果；耗时放在 TIMED_MS
TIMED_MS=0
run_timed() {
  local t0 t1 out
  t0=$(date +%s%N)
  out=$(T "$1")
  t1=$(date +%s%N)
  TIMED_MS=$(( (t1 - t0) / 1000000 ))
  echo "$out"
}
