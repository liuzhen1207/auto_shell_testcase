#!/bin/bash
# 触发器的路径模式/事件 变体实验：哪种注册方式真的会 fire()
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_trgv

for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/trgv_*.log"; done
for t in v_dev v_star v_meas v_after v_stateful; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"
Q "CREATE TIMESERIES $DB.d1.s2 DOUBLE;"

echo "=== 注册 5 个变体 ==="
Q "CREATE STATELESS TRIGGER v_dev      BEFORE INSERT ON $DB.d1        AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgv_dev.log',      tag='v_dev');"
Q "CREATE STATELESS TRIGGER v_star     BEFORE INSERT ON $DB.d1.**     AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgv_star.log',     tag='v_star');"
Q "CREATE STATELESS TRIGGER v_meas     BEFORE INSERT ON $DB.d1.s1     AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgv_meas.log',     tag='v_meas');"
Q "CREATE STATELESS TRIGGER v_after    AFTER  INSERT ON $DB.d1        AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgv_after.log',    tag='v_after');"
Q "CREATE STATEFUL  TRIGGER v_stateful BEFORE INSERT ON $DB.d1        AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgv_stateful.log', tag='v_stateful');"
echo "--- SHOW TRIGGERS ---"
Q "SHOW TRIGGERS;"

echo "=== 写入（device 级，两个测量） ==="
Q "INSERT INTO $DB.d1(timestamp, s1, s2) VALUES(1000, 1.0, 2.0);"
sleep 6
echo "=== marker 汇总 ==="
for h in "${DN[@]}"; do
  echo "--- $h"
  ssh -n -o BatchMode=yes root@$h "for f in /tmp/trgv_*.log; do [ -f \$f ] && echo \"  \$(basename \$f): \$(grep -c fire \$f) fire / \$(wc -l < \$f) 行\"; done"
done

echo "=== DN 日志里的 trigger warn ==="
ssh -n -o BatchMode=yes root@192.168.99.77 "grep -iE 'trigger' $DB_DIR/logs/log_datanode_all.log | tail -8 | cut -c1-200"

echo "=== 清理 ==="
for t in v_dev v_star v_meas v_after v_stateful; do Q "DROP TRIGGER $t;"; done
Q "DROP DATABASE $DB;"
