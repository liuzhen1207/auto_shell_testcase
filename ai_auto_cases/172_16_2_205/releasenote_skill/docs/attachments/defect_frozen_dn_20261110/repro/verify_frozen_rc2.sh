#!/bin/bash
# 在指定构建上复验「DN 冻结期间建序列 → 视图静默丢列」
NEW=${1:-v20131rc2_1110_83183d0}
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
T() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }

echo "=== 构建 $NEW 上的静默丢列复验（3 轮） ==="
LOST=0
for run in 1 2 3; do
  D=rn_frz_${run}_$(date +%H%M%S)
  Q "CREATE DATABASE $D" >/dev/null 2>&1
  T "create timeseries root.$D.dev01.s1 double" >/dev/null 2>&1
  Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**" >/dev/null 2>&1

  pid=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null)
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "kill -STOP $pid" 2>/dev/null
  sleep 12
  out=$(T "create timeseries root.$D.dev01.fr double")
  w=$(echo "$out" | head -1 | cut -c1-60)
  ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "kill -CONT $pid" 2>/dev/null
  for i in $(seq 1 30); do n=$(T "show cluster;" 2>/dev/null | grep -c Running); [ "$n" = "8" ] && break; sleep 6; done
  sleep 20
  cnt=$(Q "desc $D.v1" | grep -c '| *fr *|')
  echo "  run$run: 写入=[$w] 恢复Running=$n 列数=$cnt"
  [ "$cnt" = "0" ] && LOST=$((LOST + 1))
  Q "DROP DATABASE IF EXISTS $D" >/dev/null 2>&1
done
echo "=== 结果：3 轮中丢列 $LOST 次 ==="
