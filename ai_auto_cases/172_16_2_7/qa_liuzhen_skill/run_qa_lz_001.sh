#!/bin/bash
# QA-LZ-001：不存在用户 CLI 登录，DN 不应出现 measurements null NPE
# 在控制机（172.16.2.7）执行；被测版本/节点在下面变量中改。
set -u
TESTDB="${TESTDB:-v20131rc1_1030_ab6d3de}"
DB_ROOT="${DB_ROOT:-/data1/iotdb}"
CLI_ROOT="${CLI_ROOT:-/data2/iotdb}"
CLI="$CLI_ROOT/$TESTDB/sbin/start-cli.sh"
SEED="${SEED:-172.16.2.11}"
DN_LIST="${DN_LIST:-172.16.2.11 172.16.2.12 172.16.2.13 172.16.2.14 172.16.2.15}"
TAG=$(date +%Y%m%d_%H%M%S)
OUT="${OUT:-/tmp/qa_lz_001_$TAG}"
mkdir -p "$OUT"

[ -x "$CLI" ] || { echo "CLI 不存在: $CLI"; exit 2; }

echo "[$(date +%T)] 登录不存在的用户"
"$CLI" -h "$SEED" -u no_such_user_liuzhen -pw 'x' -e 'show databases;' > "$OUT/client.out" 2>&1
echo "client_rc=$?"
tail -3 "$OUT/client.out"
sleep 3

TS=$(date '+%Y-%m-%d %H:%M:%S')
fail=0
for ip in $DN_LIST; do
  cnt=$(ssh -o BatchMode=yes "root@$ip" \
    "awk -v ts='$TS' 'substr(\$0,1,19)>=ts && (/this\.measurements/ || /NullPointerException/)' \
      '$DB_ROOT/$TESTDB/logs/log_datanode_all.log' 2>/dev/null | wc -l" 2>/dev/null)
  cnt=${cnt:-0}
  echo "DN $ip npe_since_$TS=$cnt"
  [ "$cnt" -gt 0 ] && fail=1
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: 登录失败且 DN 无 measurements NPE"
  exit 0
else
  echo "FAIL: DN 出现 NPE，证据见各节点 log_datanode_all.log（时间 >= $TS）"
  exit 1
fi
