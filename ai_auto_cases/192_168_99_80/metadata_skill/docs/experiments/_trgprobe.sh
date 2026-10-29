#!/bin/bash
# 追查 trigger 的 fire() 为什么没被调用
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_trgprobe

for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/mdskill_trg.log"; done
Q "DROP TRIGGER trg_p;"
Q "DROP DATABASE $DB;"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"
echo "=== 建触发器 ==="
Q "CREATE STATELESS TRIGGER trg_p BEFORE INSERT ON $DB.d1 AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/mdskill_trg.log', tag='p');"
Q "SHOW TRIGGERS;"
echo "=== 插入（device 级） ==="
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(1000, 1.0);"
sleep 5
for h in "${DN[@]}"; do echo "  [$h] $(ssh -n -o BatchMode=yes root@$h "cat /tmp/mdskill_trg.log 2>/dev/null | tr '\n' '; '")"; done
echo "=== 插入（序列级） ==="
Q "INSERT INTO $DB.d1.s1(timestamp, value) VALUES(2000, 2.0);"
sleep 5
for h in "${DN[@]}"; do echo "  [$h] $(ssh -n -o BatchMode=yes root@$h "cat /tmp/mdskill_trg.log 2>/dev/null | tr '\n' '; '")"; done
echo "=== 多值插入 ==="
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(3000,3.0),(4000,4.0);"
sleep 6
for h in "${DN[@]}"; do echo "  [$h] $(ssh -n -o BatchMode=yes root@$h "cat /tmp/mdskill_trg.log 2>/dev/null | tr '\n' '; '")"; done
echo "=== DN 日志里的 trigger 相关 ==="
for h in "${DN[@]}"; do
  echo "--- $h"
  ssh -n -o BatchMode=yes root@$h "grep -iE 'trigger' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -12 | cut -c1-220"
done
echo "=== SHOW TRIGGERS 再看 ==="
Q "SHOW TRIGGERS;"
echo "=== 清理 ==="
Q "DROP TRIGGER trg_p;"
Q "DROP DATABASE $DB;"
