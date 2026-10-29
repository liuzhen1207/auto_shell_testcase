#!/bin/bash
# 隔离实验：是"设备级路径模式"还是"AFTER 事件"导致不触发
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_trgx
TAGS="a_bef_meas a_aft_meas a_bef_dev a_bef_all a_bef_star a_bef_ondot"

for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/trgx_*.log"; done
for t in $TAGS; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"
Q "CREATE TIMESERIES $DB.d1.s2 DOUBLE;"

reg(){ Q "CREATE STATELESS TRIGGER $1 BEFORE INSERT ON $2 AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgx_$1.log', tag='$1');"; }
rega(){ Q "CREATE STATELESS TRIGGER $1 AFTER INSERT ON $2 AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgx_$1.log', tag='$1');"; }

echo "=== 注册 ==="
reg  a_bef_meas  "$DB.d1.s1"
rega a_aft_meas  "$DB.d1.s1"
reg  a_bef_dev   "$DB.d1"
reg  a_bef_all   "$DB.**"
reg  a_bef_star  "$DB.d1.**"
reg  a_bef_ondot "$DB.d1.*"
Q "SHOW TRIGGERS;"

echo "=== 写入 A：device 级（s1+s2） ==="
Q "INSERT INTO $DB.d1(timestamp, s1, s2) VALUES(1000, 1.0, 2.0);"
sleep 5
echo "=== 写入 B：再写一条 device 级（s1） ==="
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(2000, 3.0);"
sleep 5

echo "=== fire 统计（三节点合计 / 各节点） ==="
for t in $TAGS; do
  tot=0; per=""
  for h in "${DN[@]}"; do
    c=$(ssh -n -o BatchMode=yes root@$h "grep -c fire /tmp/trgx_$t.log 2>/dev/null" | tr -dc '0-9')
    c=${c:-0}
    tot=$((tot+c)); per="$per $h=$c"
  done
  printf '  %-12s fire 总数=%s  (%s )\n' "$t" "$tot" "$per"
done

echo "=== 清理 ==="
for t in $TAGS; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
