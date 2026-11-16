#!/bin/bash
set -u
A=/data/iotdb/autotest
V=v20131rc2_1110_83183d0
echo "== 各节点 JVM 进程 =="
for h in 77 78 79; do
  echo -n "  .$h: "
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" 2>/dev/null
done
echo
echo "== 端口监听（7777=CN 内部? 6667=CLI, 10710/10730）=="
for h in 77 78 79; do
  echo -n "  .$h: "
  ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.$h "ss -lnt 2>/dev/null | awk '{print \$4}' | grep -oE ':(6667|10710|10730|10740|40010|7777)$' | sort -u | tr '\n' ' '" 2>/dev/null
  echo
done
echo
echo "== 用 root 登录试一下（看错误码）=="
printf 'set sql_dialect=tree;\nshow version;\n' | /data/iotdb/testdb/$V/sbin/start-cli.sh -h 192.168.99.77 -u root -pw 'TimechoDB@2021' 2>&1 | tail -4
echo
echo "== 集群启动日志尾部 =="
tail -6 "$A/rc2_regression_logs/sec_recover2.log" | cut -c1-150
echo
echo "== CN/DN 启动错误（最近）=="
ssh -o BatchMode=yes -o LogLevel=ERROR root@192.168.99.77 "ls -t /data/iotdb/$V/logs/ 2>/dev/null | head -3; grep -aE 'Exception|ERROR' /data/iotdb/$V/logs/log_confignode_all.log 2>/dev/null | tail -3 | cut -c1-170" 2>/dev/null
