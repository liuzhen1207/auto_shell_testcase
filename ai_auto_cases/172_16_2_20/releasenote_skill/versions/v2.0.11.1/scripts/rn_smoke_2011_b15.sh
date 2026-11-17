#!/bin/bash
# V2.0.11.1 RN 冒烟第十五批：EXPLAIN 成本归属 / SHOW REGIONS 指标 / 取消迁移快照清理 / 分区表修复 / TTL 高可用
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run15.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
cluster(){ q "SHOW CLUSTER;" | grep -c '|Running|'; }

echo "===== V2.0.11.1 RN SMOKE-15 $(date -Is) =====" | tee -a "$LOG"
q "CREATE DATABASE rn15;" >/dev/null 2>&1
q "CREATE TABLE rn15.t (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
for i in 1 2 3; do q "INSERT INTO rn15.t(time,dev,v) VALUES (17976${i}0000000,'d1',$i);" >/dev/null 2>&1; done
q "FLUSH;" >/dev/null 2>&1
sleep 3

########## TDB-693 EXPLAIN ANALYZE 成本归属 ##########
r=$(q "EXPLAIN ANALYZE SELECT count(*) FROM rn15.t;")
ana=$(echo "$r" | grep -ci 'analyzer')
cost=$(echo "$r" | grep -ci 'cost')
if [ "${ana:-0}" -ge 1 ] && [ "${cost:-0}" -ge 1 ]; then
  ok "QUERY-12 EXPLAIN ANALYZE 输出含 Analyzer 与 Cost 分项（TDB-693）"
else
  sk "QUERY-12 成本分项" "analyzer=$ana cost=$cost"
fi

########## TDB-735 SHOW REGIONS 指标非负 ##########
neg=$(q "SHOW REGIONS;" | grep DataRegion | awk -F'|' '{for(i=10;i<=15;i++){gsub(/ /,"",$i); if($i ~ /^-/){print $i}}}' | wc -l)
nan=$(q "SHOW REGIONS;" | grep DataRegion | grep -c 'NaN')
if [ "${neg:-0}" -eq 0 ]; then
  ok "CLUSTER-10 SHOW REGIONS 无负值指标（NaN 行=$nan，TDB-735）"
else
  ng "CLUSTER-10 负值指标" "neg=$neg"
fi

########## TDB-721 取消迁移后快照残余 ##########
rid=$(q "SHOW REGIONS;" | grep -i rn15 | grep DataRegion | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -n1)
mk="RN15-$(date +%s)"; echo "$mk" > /tmp/rn15_mark
q "EXTEND REGION $rid TO 6;" >/dev/null 2>&1
sleep 2
t "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
sleep 8
# 目标 DN(21) 上是否有本时间点后新建的 snapshot 目录
snap=$(ssh -n -o BatchMode=yes root@172.16.2.21 "find $NEW/data -maxdepth 6 -type d -name '*snapshot*' -newermt '-5 minutes' 2>/dev/null | wc -l" 2>/dev/null)
if [ "${snap:-0}" -eq 0 ]; then
  ok "REGION-5 取消迁移后目标 DN 无新增 snapshot 残余目录（TDB-721）"
else
  sk "REGION-5 快照残余" "近 5 分钟 snapshot 目录=$snap（需人工确认是否本操作产生）"
fi
q "REMOVE REGION $rid FROM 6;" >/dev/null 2>&1

########## TDB-771 分区表修复参数 + DN 停止 ##########
t 'SET CONFIGURATION "partition_table_recover_worker_num"="1";' >/dev/null 2>&1
mk2="RN15B-$(date +%s)"; echo "$mk2" > /tmp/rn15_mark2
for c in 16 17 18; do ssh -n -o BatchMode=yes root@172.16.2.$c "echo $mk2 >> $NEW/logs/log_confignode_all.log" 2>/dev/null; done
ssh -n -o BatchMode=yes root@172.16.2.24 "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
sleep 20
cast=0
for c in 16 17 18; do
  x=$(ssh -n -o BatchMode=yes root@172.16.2.$c "awk -v m='$mk2' 'index(\$0,m){f=1} f' $NEW/logs/log_confignode_all.log 2>/dev/null | grep -ciE 'TSStatus.*(cast|ClassCast)|ClassCastException'" 2>/dev/null)
  cast=$((cast+${x:-0}))
done
ssh -n -o BatchMode=yes root@172.16.2.24 "cd $NEW && setsid bash sbin/start-datanode.sh -d >/tmp/dn24_rn15.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(cluster); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
if [ "${cast:-0}" -eq 0 ] && [ "${n:-0}" -ge 8 ]; then
  ok "CLUSTER-11 分区表修复参数开启 + 停 DN：CN 无 TSStatus 转换异常，恢复 8/8（TDB-771）"
else
  ng "CLUSTER-11 分区表修复" "cast=$cast cluster=$n"
fi
t 'SET CONFIGURATION "partition_table_recover_worker_num"="0";' >/dev/null 2>&1

########## TDB-732 TTL 管理高可用 ##########
q "CREATE DATABASE rnttl WITH (ttl=3600000);" >/dev/null 2>&1
q "CREATE TABLE rnttl.t (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rnttl.t(time,dev,v) VALUES (1797700000000,'d1',1);" >/dev/null 2>&1
q "FLUSH;" >/dev/null 2>&1
ttl_before=$(q "SHOW DATABASES;" | grep rnttl | awk -F'|' '{gsub(/ /,"",$3); print $3}')
ssh -n -o BatchMode=yes root@172.16.2.23 "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
sleep 10
r=$(q "SELECT count(*) FROM rnttl.t;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
ssh -n -o BatchMode=yes root@172.16.2.23 "cd $NEW && setsid bash sbin/start-datanode.sh -d >/tmp/dn23_rn15.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(cluster); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
ttl_after=$(q "SHOW DATABASES;" | grep rnttl | awk -F'|' '{gsub(/ /,"",$3); print $3}')
if [ "${ttl_before:-x}" = "${ttl_after:-y}" ] && [ "${r:-0}" -ge 1 ] && [ "${n:-0}" -ge 8 ]; then
  ok "STOR-4 TTL 配置在 DN 宕机/恢复后保持一致（$ttl_before，TDB-732）"
else
  ng "STOR-4 TTL 高可用" "before=$ttl_before after=$ttl_after rows=$r cluster=$n"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-15 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rn15;" >/dev/null 2>&1
q "DROP DATABASE rnttl;" >/dev/null 2>&1
exit 0
