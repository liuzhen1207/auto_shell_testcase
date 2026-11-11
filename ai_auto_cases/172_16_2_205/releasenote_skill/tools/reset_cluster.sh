#!/bin/bash
# 彻底重置：杀进程 → 删 data/logs → 按序启动 → 校验（V2、空库、8/8）
set -u
NEW=${1:-v20131rc2_1110_83183d0}
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
T() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
Q() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }

echo "[$(date +%T)] 1) 停止所有进程"
for ip in $CN_LIST $DN_LIST; do
  ssh -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb' 2>/dev/null; sleep 1; pkill -9 java 2>/dev/null; sleep 1; echo -n '$ip java='; pgrep -c java" 2>/dev/null
done
sleep 3

echo "[$(date +%T)] 2) 清空 data/logs"
for ip in $CN_LIST; do
  ssh -n -o StrictHostKeyChecking=no root@$ip "rm -rf /data/iotdb/$NEW/data /data/iotdb/$NEW/logs /data/iotdb/$NEW/start_*.log; echo -n '$ip data='; ls -d /data/iotdb/$NEW/data 2>/dev/null | wc -l" 2>/dev/null
done
for ip in $DN_LIST; do
  ssh -n -o StrictHostKeyChecking=no root@$ip "rm -rf /data1/iotdb/$NEW/data /data1/iotdb/$NEW/logs /data1/iotdb/$NEW/start_*.log; echo -n '$ip data='; ls -d /data1/iotdb/$NEW/data 2>/dev/null | wc -l" 2>/dev/null
done

echo "[$(date +%T)] 3) 启动 CN26"
ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
for i in $(seq 1 30); do ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "ss -lnt 2>/dev/null | grep -q ':10710'" && break; sleep 5; done
echo "  CN26 listening=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.26 "ss -lnt 2>/dev/null | grep -c ':10710'" 2>/dev/null)"

echo "[$(date +%T)] 4) 启动 CN27/28 + 5 个 DN"
for ip in 172.16.2.27 172.16.2.28; do
  ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data/iotdb/$NEW; nohup /data/iotdb/$NEW/sbin/start-confignode.sh -H /data/iotdb/$NEW/cn.hprof > /data/iotdb/$NEW/start_cn.log 2>&1 &" 2>/dev/null
  sleep 5
done
sleep 15
for ip in $DN_LIST; do
  ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null
  sleep 3
done

echo "[$(date +%T)] 5) 等待 8/8"
n=0
for i in $(seq 1 90); do n=$(T "show cluster;" 2>/dev/null | grep -c Running); [ "$n" -ge 8 ] && break; sleep 8; done
echo "  Running=$n"

echo "[$(date +%T)] 6) 校验"
Q "show variables" 2>/dev/null | grep -i DataRegionConsensusProtocolClass
echo "  数据库列表:"
Q "show databases" 2>/dev/null | awk -F'|' 'NF>2 && $2 !~ /Database/ {gsub(/ /,"",$2); print "    "$2}'
