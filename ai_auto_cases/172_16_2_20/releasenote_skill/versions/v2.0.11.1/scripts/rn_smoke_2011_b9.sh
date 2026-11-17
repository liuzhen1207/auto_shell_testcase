#!/bin/bash
# V2.0.11.1 RN 冒烟第九批：Region 迁移/取消（TDB-737/704/707/717）
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run9.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
count_rows(){ q "SELECT count(*) FROM rnmig.t;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9'; }

echo "===== V2.0.11.1 RN SMOKE-9 $(date -Is) =====" | tee -a "$LOG"

echo "--- SETUP ---" | tee -a "$LOG"
q "CREATE DATABASE rnmig;" >/dev/null
q "CREATE TABLE rnmig.t (dev STRING TAG, v INT32 FIELD);" >/dev/null
for i in 1 2 3 4 5; do q "INSERT INTO rnmig.t(time,dev,v) VALUES (17970${i}0000000,'d1',$i);" >/dev/null; done
q "FLUSH;" >/dev/null
sleep 3
before=$(count_rows)
echo "初始行数=$before" | tee -a "$LOG"
rid=$(q "SHOW REGIONS;" | grep -i rnmig | grep DataRegion | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -n1)
echo "region=$rid" | tee -a "$LOG"

########## REG-1 CANCEL ALL MIGRATIONS 基本能力（TDB-737） ##########
r=$(t "CANCEL ALL MIGRATIONS;")
if ! has "$r" 'exception'; then
  ok "REG-1 CANCEL ALL MIGRATIONS 可执行（TDB-737）"
else
  ng "REG-1 CANCEL ALL MIGRATIONS" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi

########## REG-2 REMOVE Peer 期间取消，数据不得缺失（TDB-704） ##########
mk="RNMIG9-$(date +%s)"; echo "$mk" > /tmp/rn_mig9_mark
for n in 19 21 22 23 24; do ssh -n -o BatchMode=yes root@172.16.2.$n "echo $mk >> $NEW/logs/log_datanode_all.log" 2>/dev/null; done
q "REMOVE REGION $rid FROM 6;" >/dev/null 2>&1
sleep 2
t "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
sleep 8
after=$(count_rows)
if [ "${before:-0}" = "${after:-0}" ] && [ "${after:-0}" -gt 0 ]; then
  ok "REG-2 REMOVE Peer 期间取消迁移，数据完整（$before 行，TDB-704）"
else
  ng "REG-2 REMOVE+CANCEL 数据完整性" "before=$before after=$after"
fi

########## REG-3 EXTEND add-peer 期间取消，无 NPE / unexpected consensusGroupId（TDB-707/717） ##########
q "EXTEND REGION $rid TO 6;" >/dev/null 2>&1
sleep 2
t "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
sleep 10
bad=0
for n in 19 21 22 23 24; do
  c=$(ssh -n -o BatchMode=yes root@172.16.2.$n "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_datanode_all.log 2>/dev/null | grep -icE 'TreeSet|NullPointerException|unexpected consensusGroupId'" 2>/dev/null)
  bad=$((bad+${c:-0}))
done
if [ "$bad" -eq 0 ]; then
  ok "REG-3 add-peer 期间取消：无 TreeSet/NPE/unexpected consensusGroupId（TDB-707/717）"
else
  ng "REG-3 add-peer 取消异常" "命中=$bad"
fi

########## REG-4 取消后数据仍一致（多 DN 校验） ##########
a=$(q "SELECT count(*) FROM rnmig.t;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
b=$(bash "$CLI" -h 172.16.2.21 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM rnmig.t;" 2>&1 | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
c=$(bash "$CLI" -h 172.16.2.22 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM rnmig.t;" 2>&1 | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
if [ "${a:-0}" -gt 0 ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
  ok "REG-4 取消迁移后三个 DN 数据一致（$a 行）"
else
  ng "REG-4 数据一致性" "a=$a b=$b c=$c"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-9 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
q "DROP DATABASE rnmig;" >/dev/null 2>&1
exit 0
