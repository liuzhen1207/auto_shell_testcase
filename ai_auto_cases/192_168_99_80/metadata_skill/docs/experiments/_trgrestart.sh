#!/bin/bash
# 触发器重启持久化实验：重启后 SHOW TRIGGERS / restore() / fire() 表现
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_trgr
TAGS="r_bef r_aft r_stateful"

for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/trgr_*.log"; done
for t in $TAGS; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(1000, 1.0);"

echo "=== 注册 3 个触发器（before / after / stateful），路径用 d1.** ==="
Q "CREATE STATELESS TRIGGER r_bef      BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgr_bef.log', tag='r_bef');"
Q "CREATE STATELESS TRIGGER r_aft      AFTER  INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgr_aft.log', tag='r_aft');"
Q "CREATE STATEFUL  TRIGGER r_stateful BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgr_stateful.log', tag='r_stateful');"
Q "SHOW TRIGGERS;"

echo "=== 重启前写入 ==="
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(2000, 2.0);"
sleep 5
for t in $TAGS; do
  tot=0; for h in "${DN[@]}"; do c=$(ssh -n -o BatchMode=yes root@$h "grep -c fire /tmp/trgr_$t.log 2>/dev/null" | tr -dc '0-9'); tot=$((tot+${c:-0})); done
  echo "  重启前 $t fire=$tot"
done

echo "=== 重启集群（保留数据） ==="
cluster_stop
cluster_start

echo "=== 重启后 SHOW TRIGGERS ==="
Q "SHOW TRIGGERS;"
echo "=== 重启后 restore 事件 ==="
for t in $TAGS; do
  n=0; for h in "${DN[@]}"; do c=$(ssh -n -o BatchMode=yes root@$h "grep -c restore /tmp/trgr_$t.log 2>/dev/null" | tr -dc '0-9'); n=$((n+${c:-0})); done
  echo "  $t restore=$n"
done

echo "=== 重启后写入 ==="
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(3000, 3.0);"
sleep 6
for t in $TAGS; do
  tot=0; per=""
  for h in "${DN[@]}"; do c=$(ssh -n -o BatchMode=yes root@$h "grep -c fire /tmp/trgr_$t.log 2>/dev/null" | tr -dc '0-9'); c=${c:-0}; tot=$((tot+c)); per="$per $h=$c"; done
  echo "  重启后新增 $t fire 总=$tot ($per)"
done

echo "=== 清理 ==="
for t in $TAGS; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
