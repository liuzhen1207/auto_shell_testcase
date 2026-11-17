#!/bin/bash
# V2.0.11.1 RN 冒烟第十二批：集群/节点（TDB-760/761/748）
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run12.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
cluster(){ q "SHOW CLUSTER;" | grep -c '|Running|'; }

echo "===== V2.0.11.1 RN SMOKE-12 $(date -Is) =====" | tee -a "$LOG"

########## TDB-760 DN 重启期间创建 region ##########
echo "--- DN RESTART + REGION CREATE ---" | tee -a "$LOG"
ssh -n -o BatchMode=yes root@172.16.2.23 "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
sleep 8
q "CREATE DATABASE rncr;" >/dev/null 2>&1
q "CREATE TABLE rncr.t (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rncr.t(time,dev,v) VALUES (1797300000000,'d1',1);" >/dev/null 2>&1
ssh -n -o BatchMode=yes root@172.16.2.23 "cd $NEW && setsid bash sbin/start-datanode.sh -d >/tmp/dn23_rncr.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(cluster); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
sleep 6
r=$(q "SELECT count(*) FROM rncr.t;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
# region 是否在所有副本节点可见
regs=$(q "SHOW REGIONS;" | grep -i rncr | grep -c DataRegion)
if [ "${n:-0}" -ge 8 ] && [ "${r:-0}" -eq 1 ] && [ "${regs:-0}" -ge 2 ]; then
  ok "CLUSTER-6 DN 重启期间建库/写入，恢复后数据与 region 完整（TDB-760）"
else
  ng "CLUSTER-6 region 创建期间 DN 重启" "cluster=$n rows=$r regionRows=$regs"
fi

########## TDB-761 删除只影响本表 region ##########
echo "--- DELETE ISOLATION ---" | tee -a "$LOG"
q "CREATE DATABASE rniso;" >/dev/null 2>&1
q "CREATE TABLE rniso.a (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "CREATE TABLE rniso.b (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
for i in 1 2 3; do
  q "INSERT INTO rniso.a(time,dev,v) VALUES (17973${i}0000000,'d1',$i);" >/dev/null 2>&1
  q "INSERT INTO rniso.b(time,dev,v) VALUES (17973${i}0000000,'d1',$i);" >/dev/null 2>&1
done
q "FLUSH;" >/dev/null 2>&1
sleep 3
q "DELETE FROM rniso.a WHERE time <= 1797320000000;" >/dev/null 2>&1
sleep 3
ca=$(q "SELECT count(*) FROM rniso.a;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
cb=$(q "SELECT count(*) FROM rniso.b;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
if [ "${ca:-0}" -eq 1 ] && [ "${cb:-0}" -eq 3 ]; then
  ok "CLUSTER-7 删除仅作用于目标表（A=$ca 行，B=$cb 行，TDB-761）"
else
  ng "CLUSTER-7 删除隔离" "A=$ca B=$cb"
fi

########## TDB-748 schema cache 一致性 ##########
echo "--- SCHEMA CACHE ---" | tee -a "$LOG"
a=$(q "SHOW TABLES FROM rniso;" | grep -cE '\| *(a|b)')
b=$(bash "$CLI" -h 172.16.2.21 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SHOW TABLES FROM rniso;" 2>&1 | grep -cE '\| *(a|b)')
c=$(bash "$CLI" -h 172.16.2.24 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SHOW TABLES FROM rniso;" 2>&1 | grep -cE '\| *(a|b)')
if [ "${a:-0}" -eq 2 ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
  ok "CLUSTER-8 三个 DN 的 schema cache 一致（表数=$a，TDB-748）"
else
  ng "CLUSTER-8 schema cache 一致性" "a=$a b=$b c=$c"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-12 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rncr;" >/dev/null 2>&1
q "DROP DATABASE rniso;" >/dev/null 2>&1
exit 0
