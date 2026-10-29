#!/bin/bash
# Hard reset: kill every IoTDB java process on the 8 nodes, wipe data/logs, then start in strict order.
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -f "$BASE/conf/env.conf" ] && . "$BASE/conf/env.conf"
NEW=${NEW:-v20121rc12_1027_c05111d}
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"

echo "[$(date +%T)] kill all iotdb java"
for ip in $CN_LIST $DN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb' 2>/dev/null; sleep 2; n=\$(pgrep -c java); if [ \"\$n\" != 0 ]; then pkill -9 java; sleep 2; fi; echo -n '$ip java='; pgrep -c java" 2>/dev/null
done
sleep 3

echo "[$(date +%T)] wipe data/logs"
for ip in $CN_LIST; do ssh -o StrictHostKeyChecking=no root@$ip "rm -rf /data/iotdb/$NEW/data /data/iotdb/$NEW/logs /data/iotdb/$NEW/start_*.log" 2>/dev/null; done
for ip in $DN_LIST; do ssh -o StrictHostKeyChecking=no root@$ip "rm -rf /data1/iotdb/$NEW/data /data1/iotdb/$NEW/logs /data1/iotdb/$NEW/start_*.log" 2>/dev/null; done

echo "[$(date +%T)] start CN 26"
ssh -o StrictHostKeyChecking=no root@172.16.2.26 "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
for i in $(seq 1 24); do
  ssh -o StrictHostKeyChecking=no root@172.16.2.26 "ss -lnt 2>/dev/null | grep -q ':10710'" && break
  sleep 5
done
echo "  CN 26 listening: $(ssh -o StrictHostKeyChecking=no root@172.16.2.26 "ss -lnt 2>/dev/null | grep -c ':10710'")"

echo "[$(date +%T)] start CN 27/28"
for ip in 172.16.2.27 172.16.2.28; do
  ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
  sleep 4
done

echo "[$(date +%T)] ensure 3 CN processes alive (retry up to 4 rounds)"
for round in 1 2 3 4; do
  bad=0
  for ip in $CN_LIST; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.service.ConfigNode'" 2>/dev/null)
    [ "${n:-0}" = "0" ] && bad=$((bad + 1))
  done
  [ "$bad" = "0" ] && { echo "  all 3 CN alive"; break; }
  echo "  round $round: $bad CN down, restarting"
  for ip in $CN_LIST; do
    n=$(ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c -f 'com.timecho.iotdb.service.ConfigNode'" 2>/dev/null)
    if [ "${n:-0}" = "0" ]; then
      ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
      sleep 5
    fi
  done
  sleep 15
done

echo "[$(date +%T)] wait CN quorum"
for i in $(seq 1 24); do
  l=$($CLI -h 172.16.2.2 -p 6667 -u root -pw TimechoDB@2021 -e "show cluster;" 2>/dev/null | grep -c "ConfigNode")
  echo "  [$i] cn_rows=$l"
  [ "$l" -ge 3 ] && break
  sleep 5
done

echo "[$(date +%T)] start DN"
for ip in $DN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null
  sleep 2
done

echo "[$(date +%T)] wait 8 nodes"
for i in $(seq 1 60); do
  n=$($CLI -h 172.16.2.2 -p 6667 -u root -pw TimechoDB@2021 -e "show cluster;" 2>/dev/null | grep -cE "Running")
  echo "  [$i] running=$n"
  [ "$n" -ge 8 ] && { echo READY; exit 0; }
  sleep 8
done
echo NOT_READY
for ip in $CN_LIST $DN_LIST; do echo -n "$ip java="; ssh -o StrictHostKeyChecking=no root@$ip "pgrep -c java" 2>/dev/null; done
exit 1
