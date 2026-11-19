#!/bin/bash
# TDB-1497 连接数上限探针驱动
#   usage: cli_conn_probe.sh probe <user> <pw> <n>   # 维持 n 个连接后探测第 n+1 个的错误文案
#          cli_conn_probe.sh cli   <user> <pw> <n>   # 占满 n 个连接后用 CLI 连接，检查 CLI 报错文案
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
NEW=${NEW:-v20131rc3_1117_ac7f95e}
HOST=${HOST:-172.16.2.2}
BUILD=/data2/iotdb/$NEW
CP="$BUILD/lib/timechodb-server-2.0.13.1.jar:$BUILD/lib/common-dependency.jar"
CLI=$BUILD/sbin/start-cli.sh
DIR=/tmp/connprobe_$$
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

if ! javac -cp "$CP" -d "$DIR" "$BASE/tools/ConnLimitProbe.java" > "$DIR/javac.log" 2>&1; then
  echo "COMPILE_FAILED"; head -3 "$DIR/javac.log"; exit 3
fi

mode=${1:?mode}; user=${2:?user}; pw=${3:?pw}; n=${4:?n}

case "$mode" in
  probe)
    java -cp "$CP:$DIR" ConnLimitProbe probe "$HOST" 6667 "$user" "$pw" "$n" 2>&1
    ;;
  cli)
    java -cp "$CP:$DIR" ConnLimitProbe hold "$HOST" 6667 "$user" "$pw" "$n" 120 > "$DIR/hold.log" 2>&1 &
    HPID=$!
    for _ in $(seq 1 30); do grep -q HOLDING "$DIR/hold.log" 2>/dev/null && break; sleep 1; done
    if ! grep -q HOLDING "$DIR/hold.log" 2>/dev/null; then
      echo "CLI_HOLD_FAILED"; cat "$DIR/hold.log" | head -3; kill -9 $HPID 2>/dev/null; exit 0
    fi
    out=$(timeout 60 "$CLI" -h "$HOST" -p 6667 -u "$user" -pw "$pw" -sql_dialect tree -e "show cluster" 2>&1)
    rc=$?
    kill -9 $HPID 2>/dev/null
    wait $HPID 2>/dev/null
    echo "CLI_RC=$rc"
    echo "CLI_OUTPUT=$(echo "$out" | tr '\n' '|' | cut -c1-400)"
    if echo "$out" | grep -q "Can't execute sql because"; then echo "CLI_HAS_CANT_EXECUTE=true"; else echo "CLI_HAS_CANT_EXECUTE=false"; fi
    if echo "$out" | grep -q "not enough connection resources available"; then echo "CLI_HAS_RESOURCE_MSG=true"; else echo "CLI_HAS_RESOURCE_MSG=false"; fi
    if echo "$out" | grep -qi "Check whether the server exists or is alive"; then echo "CLI_HAS_OLD_MSG=true"; else echo "CLI_HAS_OLD_MSG=false"; fi
    if echo "$out" | grep -qE "not enough connection resources available|Insufficient connection pool resources"; then echo "CLI_HAS_CLEAR_MSG=true"; else echo "CLI_HAS_CLEAR_MSG=false"; fi
    if [ "$rc" -ne 0 ]; then echo "CLI_REJECTED=true"; else echo "CLI_REJECTED=false"; fi
    ;;
  *)
    echo "unknown mode: $mode"; exit 2 ;;
esac
