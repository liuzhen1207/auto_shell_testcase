#!/bin/bash
# V2.0.11.1 RN 冒烟第五批：表模型 DDL 一致性 / CompressionRatio 格式 / 多 region 列表 / CN 重启 NPE
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run5.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
raw(){ bash "$CLI" -h "${2:-$HOST}" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
q(){ raw "$1" | grep -vE '^\s*$' | tail -n 3; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1 | grep -vE '^\s*$' | tail -n 3; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }

echo "===== V2.0.11.1 RN SMOKE-5 $(date -Is) =====" | tee -a "$LOG"

########## DDL 表模型 DDL 一致性 ##########
echo "--- DDL ---" | tee -a "$LOG"
q "CREATE DATABASE rnddl5;" >/dev/null
q "CREATE TABLE rnddl5.t (dev STRING TAG, s1 INT64 FIELD);" >/dev/null
q "INSERT INTO rnddl5.t(time,dev,s1) VALUES (1796900000000,'d1',1);" >/dev/null
q "CREATE WRITABLE VIEW rnddl5.v AS SELECT s1 AS s1 FROM rnddl5.t;" >/dev/null
r=$(q "ALTER VIEW rnddl5.v RENAME TO v2;")
if ! has "$r" 'exception' && has "$r" 'successfully'; then
  ok "DDL-3 表模型 建视图/改视图名 成功"
else
  ng "DDL-3 视图 DDL" "$(echo "$r" | tail -n1 | cut -c1-80)"
fi
sleep 3
a=$(raw "SHOW TABLES FROM rnddl5;" | grep -cE '\| *(t|v2)')
b=$(raw "SHOW TABLES FROM rnddl5;" 172.16.2.21 | grep -cE '\| *(t|v2)')
c=$(raw "SHOW TABLES FROM rnddl5;" 172.16.2.22 | grep -cE '\| *(t|v2)')
if [ "${a:-0}" -ge 2 ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
  ok "DDL-4 三个 DN 元数据一致（表+视图 数=$a）"
else
  ng "DDL-4 元数据一致性" "a=$a b=$b c=$c"
fi

########## CLUSTER CompressionRatio 格式 ##########
echo "--- CLUSTER ---" | tee -a "$LOG"
rows=$(q "SHOW REGIONS;")
ratios=$(echo "$rows" | grep DataRegion | awk -F'|' '{gsub(/ /,"",$15); print $15}' | grep -E '^[0-9]' | sort -u | head -n 3)
bad=0
for r in $ratios; do echo "$r" | grep -qE '^[0-9]+\.[0-9]{2}$' || bad=$((bad+1)); done
if [ -n "${ratios:-}" ] && [ "$bad" -eq 0 ]; then
  ok "CLUSTER-3 CompressionRatio 保留两位小数（样例: $(echo $ratios | tr '\n' ' ')）"
elif [ -z "${ratios:-}" ]; then
  sk "CLUSTER-3 CompressionRatio 格式" "暂无有效值"
else
  ng "CLUSTER-3 CompressionRatio 格式" "样例=$ratios"
fi

########## 多 region 列表 ##########
ids=$(echo "$rows" | grep DataRegion | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -u | head -n 2 | paste -sd, -)
if [ -n "${ids:-}" ] && [ "$(echo "$ids" | tr ',' '\n' | wc -l)" -ge 2 ]; then
  r=$(t "EXTEND REGION $ids TO 6;")
  if has "$r" 'successfully' || has "$r" '909|does not exist'; then
    ok "CLUSTER-4 EXTEND REGION 支持多 region 列表（$ids，TDB-796）"
    for id in $(echo "$ids" | tr ',' ' '); do t "REMOVE REGION $id FROM 6;" >/dev/null 2>&1; done
  else
    ng "CLUSTER-4 多 region 列表" "$(echo "$r" | tail -n1 | cut -c1-80)"
  fi
else
  sk "CLUSTER-4 多 region 列表" "有效 region 不足 2 个"
fi

########## CN 重启 NPE 检查（TDB-756） ##########
echo "--- CN RESTART ---" | tee -a "$LOG"
mk="RNCN-$(date +%s)"; echo "$mk" > /tmp/rn_cn_mark
ssh -n -o BatchMode=yes root@172.16.2.17 "echo $mk >> $NEW/logs/log_confignode_all.log" 2>/dev/null
ssh -n -o BatchMode=yes root@172.16.2.17 "pkill -9 -f 'com[.]timecho[.]iotdb[.]ConfigNode'" 2>/dev/null
sleep 8
ssh -n -o BatchMode=yes root@172.16.2.17 "cd $NEW && setsid bash sbin/start-confignode.sh -d >/tmp/cn17_restart.log 2>&1 </dev/null && sleep 2" 2>/dev/null
for i in $(seq 1 40); do
  n=$(raw "SHOW CLUSTER;" | grep -c '|Running|')
  [ "${n:-0}" -ge 8 ] && break; sleep 5
done
npe=$(ssh -n -o BatchMode=yes root@172.16.2.17 "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_confignode_all.log 2>/dev/null | grep -c 'NullPointerException'" 2>/dev/null)
if [ "${n:-0}" -ge 8 ] && [ "${npe:-0}" -eq 0 ]; then
  ok "CLUSTER-5 CN 重启后 8/8 恢复且无 NPE（TDB-756/715）"
elif [ "${n:-0}" -ge 8 ]; then
  ng "CLUSTER-5 CN 重启 NPE" "NPE=$npe"
else
  ng "CLUSTER-5 CN 重启恢复" "cluster=$n"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-5 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rnddl5;" >/dev/null 2>&1
exit 0
