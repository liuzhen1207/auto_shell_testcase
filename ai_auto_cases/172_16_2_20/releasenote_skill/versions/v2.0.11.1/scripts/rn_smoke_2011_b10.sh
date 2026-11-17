#!/bin/bash
# V2.0.11.1 RN 冒烟第十批：表模型 DDL（TDB-688/691）—— DN 异常/重启期间的 DROP DATABASE
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run10.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
cluster(){ q "SHOW CLUSTER;" | grep -c '|Running|'; }

echo "===== V2.0.11.1 RN SMOKE-10 $(date -Is) =====" | tee -a "$LOG"

# 准备库
for db in rnd1 rnd2 rnd3; do
  q "CREATE DATABASE $db;" >/dev/null
  q "CREATE TABLE $db.t (dev STRING TAG, v INT32 FIELD);" >/dev/null
  q "INSERT INTO $db.t(time,dev,v) VALUES (1797100000000,'d1',1);" >/dev/null
done
q "FLUSH;" >/dev/null
sleep 3

# 打标记
mk="RNDDL-$(date +%s)"; echo "$mk" > /tmp/rn_ddl_mark
for n in 16 17 18; do ssh -n -o BatchMode=yes root@172.16.2.$n "echo $mk >> $NEW/logs/log_confignode_all.log" 2>/dev/null; done

echo "--- 停 DN22 制造 Unknown ---" | tee -a "$LOG"
ssh -n -o BatchMode=yes root@172.16.2.22 "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
sleep 12

echo "--- DN 未知期间连续 DROP DATABASE ---" | tee -a "$LOG"
for i in 1 2 3; do
  r=$(q "DROP DATABASE rnd1;")
  echo "drop#$i: $(echo "$r" | tail -n1 | cut -c1-80)" >> "$LOG"
done
r1=$(q "DROP DATABASE rnd2;")
r2=$(q "DROP DATABASE rnd3;")
sleep 5

echo "--- 重启 DN22 ---" | tee -a "$LOG"
ssh -n -o BatchMode=yes root@172.16.2.22 "cd $NEW && setsid bash sbin/start-datanode.sh -d >/tmp/dn22_ddl_restart.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(cluster); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
echo "cluster=$n" | tee -a "$LOG"

# 检查 CN 日志中的异常（TDB-688 restartDataNode NPE / TDB-691 线程占用）
npe=0; sem=0; thr=0
for c in 16 17 18; do
  a=$(ssh -n -o BatchMode=yes root@172.16.2.$c "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_confignode_all.log 2>/dev/null | grep -c 'NullPointerException'" 2>/dev/null); npe=$((npe+${a:-0}))
  b=$(ssh -n -o BatchMode=yes root@172.16.2.$c "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_confignode_all.log 2>/dev/null | grep -c 'SemanticException'" 2>/dev/null); sem=$((sem+${b:-0}))
  d=$(ssh -n -o BatchMode=yes root@172.16.2.$c "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_confignode_all.log 2>/dev/null | grep -ciE 'procedure.*timeout|thread.*(block|stuck)|RemoveRegionGroupProcedure.*(fail|timeout)'" 2>/dev/null); thr=$((thr+${d:-0}))
done

if [ "${npe:-0}" -eq 0 ]; then
  ok "DDL-5 DN 重启期间 CN 无 restartDataNode NPE（TDB-688）"
else
  ng "DDL-5 restartDataNode NPE" "npe=$npe"
fi
if [ "${thr:-0}" -eq 0 ] && [ "${sem:-0}" -eq 0 ]; then
  ok "DDL-6 连续 DROP DATABASE 无 Procedure 超时/SemanticException（TDB-691）"
else
  ng "DDL-6 Procedure 超时/SemanticException" "timeout=$thr semantic=$sem"
fi

# 元数据一致性：库已删除，表不存在
left=$(q "SHOW DATABASES;" | grep -cE 'rnd1|rnd2|rnd3')
if [ "${n:-0}" -ge 8 ] && [ "${left:-0}" -eq 0 ]; then
  ok "DDL-7 集群 8/8 且三个库已删除，元数据一致"
else
  ng "DDL-7 元数据一致性" "cluster=$n left=$left"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-10 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
exit 0
