#!/bin/bash
# 追查：COUNT TIMESERIES=2000 但 SHOW TIMESERIES 返回 2001 行（多出来的是什么）
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 180 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 120 -e "$1" 2>&1; }
DB=root.md_scaleprobe
N_DEV=200; M=10

Q "DROP DATABASE $DB"
stmts="CREATE DATABASE $DB;"
i=0
while [ "$i" -lt "$N_DEV" ]; do
  meas=""; j=1
  while [ "$j" -le "$M" ]; do [ -n "$meas" ] && meas="$meas, "; meas="${meas}s${j} INT32"; j=$((j+1)); done
  stmts="$stmts
CREATE ALIGNED TIMESERIES $DB.d${i}(${meas});"
  i=$((i+1))
done
printf '%s\n' "$stmts" | session_tree >/dev/null

echo "=== COUNT ==="
Q "COUNT TIMESERIES $DB.**;"
echo "=== SHOW 行数 ==="
Q "SHOW TIMESERIES $DB.**;" > /tmp/show_ts.txt
grep -cE '^\|' /tmp/show_ts.txt
echo "=== 解析后的路径集合大小 ==="
grep -E '^\|' /tmp/show_ts.txt | grep -vE '^\|[-+ ]+\|$' | tail -n +2 | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' | sort > /tmp/paths.txt
wc -l < /tmp/paths.txt
echo "=== 重复路径 ==="
uniq -d /tmp/paths.txt | head
echo "=== 不符合 d<数字>.s<数字> 的路径 ==="
grep -vE "^${DB}\.d[0-9]+\.s[0-9]+$" /tmp/paths.txt | head
echo "=== 每个设备的测量数分布 ==="
sed -E "s/^${DB}\.d([0-9]+)\..*/\1/" /tmp/paths.txt | sort -n | uniq -c | awk '{print $1}' | sort | uniq -c
echo "=== 头部 5 行原始输出 ==="
head -8 /tmp/show_ts.txt
echo "=== 尾部 5 行原始输出 ==="
tail -6 /tmp/show_ts.txt
echo "=== 单设备精确查询 (d0 / d199) ==="
Q "COUNT TIMESERIES $DB.d0.**;"
Q "COUNT TIMESERIES $DB.d199.**;"
echo "=== 清理 ==="
Q "DROP DATABASE $DB"
