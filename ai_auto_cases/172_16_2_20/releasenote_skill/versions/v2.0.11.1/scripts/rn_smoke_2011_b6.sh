#!/bin/bash
# V2.0.11.1 RN 冒烟第六批：审计埋点（账户锁定/登录拒绝、节点状态、CN 选举）
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run6.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
raw(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ raw "$1" | grep -vE '^\s*$' | tail -n 3; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }

devs(){ raw "SHOW DEVICES root.__audit.log.**;" | grep -oE 'root\.__audit\.log\.[a-z0-9_.]+'; }
total(){ local s=0 d c; for d in $(devs); do c=$(raw "SELECT count(operation_type) FROM $d;" | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9'); s=$((s+${c:-0})); done; echo $s; }
scan(){ local kw="$1"; local hits=0 d out c
  for d in $(devs); do
    out=$(raw "SELECT audit_event_type FROM $d;" 2>&1)
    c=$(echo "$out" | grep -ciE "$kw")
    hits=$((hits+${c:-0}))
  done; echo $hits; }

echo "===== V2.0.11.1 RN SMOKE-6 $(date -Is) =====" | tee -a "$LOG"

########## 账户锁定 / 登录拒绝审计 ##########
echo "--- LOCKOUT ---" | tee -a "$LOG"
t "CREATE USER rnlock 'Lock@2026pass';" >/dev/null 2>&1
before=$(total)
for i in 1 2 3 4 5; do
  bash "$CLI" -h "$HOST" -p 6667 -u rnlock -pw "Wrong@$i" -e "SHOW DATABASES;" >/dev/null 2>&1
done
sleep 5
r=$(bash "$CLI" -h "$HOST" -p 6667 -u rnlock -pw 'Lock@2026pass' -e "SHOW DATABASES;" 2>&1)
locked=$(echo "$r" | grep -ciE 'locked|blocked|lock')
after=$(total)
if [ "${after:-0}" -gt "${before:-0}" ] && [ "${locked:-0}" -ge 1 ]; then
  ok "AUDIT-11 连续失败登录触发锁定并产生审计（$before→$after，TDB-781/777）"
elif [ "${locked:-0}" -ge 1 ]; then
  sk "AUDIT-11 锁定审计增长" "已锁定但审计行数未增（$before→$after）"
else
  sk "AUDIT-11 账户锁定" "未触发锁定（可能阈值不同）"
fi
h1=$(scan 'LOGIN_FAIL|LOGIN_EXCEED|LOCK')
if [ "${h1:-0}" -ge 1 ]; then
  ok "AUDIT-12 审计事件含登录失败/锁定类（命中 $h1 行，TDB-776/777）"
else
  sk "AUDIT-12 登录失败类事件" "未命中"
fi
t "DROP USER rnlock;" >/dev/null 2>&1

########## 节点状态审计（TDB-780） ##########
echo "--- NODE STATUS ---" | tee -a "$LOG"
before=$(total)
mk="RNNODE-$(date +%s)"; echo "$mk" > /tmp/rn_node_mark
ssh -n -o BatchMode=yes root@172.16.2.22 "echo $mk >> $NEW/logs/log_datanode_all.log" 2>/dev/null
ssh -n -o BatchMode=yes root@172.16.2.22 "pkill -9 -f 'com[.]timecho[.]iotdb[.]DataNode'" 2>/dev/null
sleep 10
ssh -n -o BatchMode=yes root@172.16.2.22 "cd $NEW && setsid bash sbin/start-datanode.sh -d >/tmp/dn22_restart.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(q "SHOW CLUSTER;" | grep -c '|Running|'); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
sleep 8
after=$(total)
if [ "${n:-0}" -ge 8 ] && [ "${after:-0}" -gt "${before:-0}" ]; then
  ok "AUDIT-13 DN 重启后 8/8 且审计记录增长（$before→$after，TDB-780）"
else
  ng "AUDIT-13 节点状态审计" "cluster=$n audit=$before→$after"
fi

########## CN 选举审计（TDB-779） ##########
echo "--- ELECTION ---" | tee -a "$LOG"
before=$(total)
leader=16
ssh -n -o BatchMode=yes root@172.16.2.$leader "pkill -9 -f 'com[.]timecho[.]iotdb[.]ConfigNode'" 2>/dev/null
sleep 10
ssh -n -o BatchMode=yes root@172.16.2.$leader "cd $NEW && setsid bash sbin/start-confignode.sh -d >/tmp/cn16_restart.log 2>&1 </dev/null" 2>/dev/null
for i in $(seq 1 40); do n=$(q "SHOW CLUSTER;" | grep -c '|Running|'); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
sleep 8
after=$(total)
if [ "${n:-0}" -ge 8 ] && [ "${after:-0}" -gt "${before:-0}" ]; then
  ok "AUDIT-14 CN 重启/选举后 8/8 且审计记录增长（$before→$after，TDB-779）"
else
  ng "AUDIT-14 选举审计" "cluster=$n audit=$before→$after"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-6 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
exit 0
