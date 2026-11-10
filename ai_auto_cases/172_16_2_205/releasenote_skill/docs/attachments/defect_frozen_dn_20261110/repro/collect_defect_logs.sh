#!/bin/bash
# 复现「DN 冻结期间建序列 → 视图静默丢列」并抓取全节点日志切片
NEW=${1:-v20131rc2_1110_83183d0}
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
T() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
CN="172.16.2.26 172.16.2.27 172.16.2.28"
DN="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
OUT=/tmp/defect_logs_$(date +%H%M%S)
mkdir -p "$OUT"
D=defect_frozen_$(date +%H%M%S)
echo "OUT=$OUT"
echo "DB=$D"

Q "CREATE DATABASE $D" >/dev/null 2>&1
T "create timeseries root.$D.dev01.s1 double" >/dev/null 2>&1
Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**" >/dev/null 2>&1

declare -A BC BD
for ip in $CN; do
  BC[$ip]=$(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < /data/iotdb/$NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null)
done
for ip in $DN; do
  BD[$ip]=$(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)
done

PID=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null)
echo "[$(date +%T)] 冻结 DN6 pid=$PID"
ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "kill -STOP $PID" 2>/dev/null
sleep 12
echo "[$(date +%T)] 冻结期间建序列"
for i in 1 2 3 4 5 6; do
  OUTS=$(T "create timeseries root.$D.dev01.frozen_col double")
  echo "  try$i: $(echo "$OUTS" | head -1 | cut -c1-80)"
  echo "$OUTS" | grep -qi success && break
  sleep 8
done
echo "[$(date +%T)] 恢复 DN6"
ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "kill -CONT $PID" 2>/dev/null
for i in $(seq 1 30); do n=$(T "show cluster;" 2>/dev/null | grep -c Running); [ "$n" = "8" ] && break; sleep 6; done
echo "  恢复后 Running=$n"
sleep 25
CNT=$(Q "desc $D.v1" | grep -c 'frozen_col')
echo "[$(date +%T)] 视图含 frozen_col 列数 = $CNT  （0 = 丢列复现）"

# 抓日志切片：窗口内的 WARN/ERROR + 提及库名的行
for ip in $DN; do
  start=${BD[$ip]:-0}
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -E 'WARN|ERROR' | head -80" 2>/dev/null > "$OUT/dn_${ip##*.}_warn_err.log"
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) /data1/iotdb/$NEW/logs/log_datanode_all.log 2>/dev/null | grep -F '$D' | head -30" 2>/dev/null > "$OUT/dn_${ip##*.}_dbmention.log"
done
for ip in $CN; do
  start=${BC[$ip]:-0}
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) /data/iotdb/$NEW/logs/log_confignode_all.log 2>/dev/null | grep -E 'WARN|ERROR' | head -80" 2>/dev/null > "$OUT/cn_${ip##*.}_warn_err.log"
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) /data/iotdb/$NEW/logs/log_confignode_all.log 2>/dev/null | grep -F '$D' | head -30" 2>/dev/null > "$OUT/cn_${ip##*.}_dbmention.log"
done

echo "=== 各节点窗口内 WARN/ERROR 行数 / 提及库名行数 ==="
for f in "$OUT"/*_warn_err.log; do
  [ -f "$f" ] && echo "  $(basename "$f"): $(wc -l < "$f")"
done
for f in "$OUT"/*_dbmention.log; do
  [ -f "$f" ] && echo "  $(basename "$f"): $(wc -l < "$f")"
done

echo "=== 提及库名的行（若有） ==="
cat "$OUT"/*_dbmention.log 2>/dev/null | head -20
echo "=== 结果 ==="
echo "DB=$D LOST=$([ "$CNT" = "0" ] && echo yes || echo no) OUT=$OUT"
