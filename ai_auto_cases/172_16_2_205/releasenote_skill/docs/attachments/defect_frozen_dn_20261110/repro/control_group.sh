#!/bin/bash
# 对照组：同环境不冻结，重复 N 轮「建视图 → 新增测点 → 检查补列」，统计成功率与补列时延
NEW=${1:-v20131rc2_1110_83183d0}
N=${2:-10}
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
T() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }

echo "=== 对照组（不冻结）：$N 轮 ==="
SUC=0; FAIL=0
printf "%-4s %-28s %-8s %-8s\n" "#" "DB" "列出现" "时延(ms)"
for i in $(seq 1 $N); do
  D=ctl_$(date +%H%M%S)_$i
  Q "CREATE DATABASE $D" >/dev/null 2>&1
  T "create timeseries root.$D.dev01.s1 double" >/dev/null 2>&1
  Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**" >/dev/null 2>&1
  T0=$(date +%s%N)
  T "create timeseries root.$D.dev01.newcol double" >/dev/null 2>&1
  got=0; ms=0
  for k in $(seq 1 60); do
    if Q "desc $D.v1" | grep -q 'newcol'; then
      T1=$(date +%s%N); ms=$(( (T1 - T0) / 1000000 )); got=1; break
    fi
    sleep 0.25
  done
  if [ "$got" = "1" ]; then SUC=$((SUC+1)); else FAIL=$((FAIL+1)); ms=">15000"; fi
  printf "%-4s %-28s %-8s %-8s\n" "$i" "$D" "$([ "$got" = 1 ] && echo 是 || echo 否)" "$ms"
  Q "DROP DATABASE IF EXISTS $D" >/dev/null 2>&1
done
echo "=== 对照结果：成功 $SUC / $N，失败 $FAIL ==="
