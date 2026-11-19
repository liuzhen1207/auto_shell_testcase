#!/bin/bash
# 重启全部 DataNode（用于 dn_rpc_max_concurrent_client_num 等需重启生效的配置）
# usage: restart_dns.sh
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
for _p in "$BASE/lib/lib_rn.sh"; do [ -f "$_p" ] && . "$_p" && break; done

echo "[$(date +%T)] 停止全部 DN"
for ip in $DN_LIST; do
  ssh -n -o StrictHostKeyChecking=no root@$ip "pkill -9 -f 'com.timecho.iotdb.DataNode' 2>/dev/null; sleep 1; pgrep -c -f 'com.timecho.iotdb.DataNode' || true" 2>/dev/null | sed "s/^/  $ip dn_proc=/"
done

echo "[$(date +%T)] 启动全部 DN"
for ip in $DN_LIST; do
  start_dn "$ip"
done

echo "[$(date +%T)] 等待集群 8/8"
RN_USER=${RN_USER:-root}; RN_PW=${RN_PW:-TimechoDB@2021}
if [ "$RN_USER" = "root" ]; then
  CL() { T "show cluster;" 2>/dev/null; }
else
  CL() { L "$RN_USER" "$RN_PW" "show cluster" 2>/dev/null; }
fi
ok8=0
for i in $(seq 1 60); do
  n=$(CL | grep -c Running)
  [ "${n:-0}" -ge 8 ] && { ok8=1; break; }
  sleep 5
done
if [ "$ok8" = "1" ]; then echo "  READY"; else echo "  TIMEOUT：$(CL | grep -c Running)/8"; fi
