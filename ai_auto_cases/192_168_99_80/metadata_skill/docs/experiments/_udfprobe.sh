#!/bin/bash
# UDF / Trigger 手工验证（写用例前先摸清真实行为）
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_udfprobe

echo "##### 0) 清理 #####"
Q "DROP FUNCTION md_double;"
Q "DROP FUNCTION md_boom;"
Q "DROP TRIGGER trg_md_probe;"
Q "DROP DATABASE $DB;"
for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/mdskill_trg.log"; done

echo "##### 1) 建库与数据 #####"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(1000, 1.5), (2000, 2.5), (3000, 3.5);"
echo "--- 原始数据 ---"
Q "SELECT s1 FROM $DB.d1;"

echo "##### 2) 注册 UDF（USING URI） #####"
Q "CREATE FUNCTION md_double AS 'mdskill.MdUdtf' USING URI '$JARURI';"
echo "--- SHOW FUNCTIONS 里找 md_double ---"
Q "SHOW FUNCTIONS;" | grep -i md_double
echo "--- 执行 UDF（期望 3.0/5.0/7.0） ---"
Q "SELECT md_double(s1) FROM $DB.d1;"
echo "--- 带属性执行（factor=3，期望 4.5/7.5/10.5） ---"
Q "SELECT md_double(s1, 'factor'='3') FROM $DB.d1;"

echo "##### 3) 会抛异常的 UDF #####"
Q "CREATE FUNCTION md_boom AS 'mdskill.MdUdtfErr' USING URI '$JARURI';"
Q "SHOW FUNCTIONS;" | grep -i md_boom
echo "--- 执行（期望报错） ---"
Q "SELECT md_boom(s1) FROM $DB.d1;" | head -6

echo "##### 4) 失败路径 #####"
echo "--- 不存在的类 ---"
Q "CREATE FUNCTION md_nope AS 'mdskill.NoSuchClass' USING URI '$JARURI';" | head -4
echo "--- 不存在的 jar ---"
Q "CREATE FUNCTION md_nope2 AS 'mdskill.MdUdtf' USING URI 'file:///data/iotdb/udf_md/nosuch.jar';" | head -4
echo "--- 重名注册 ---"
Q "CREATE FUNCTION md_double AS 'mdskill.MdUdtf' USING URI '$JARURI';" | head -4

echo "##### 5) Trigger #####"
Q "CREATE STATELESS TRIGGER trg_md_probe BEFORE INSERT ON $DB.d1 AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/mdskill_trg.log', tag='t1');"
echo "--- SHOW TRIGGERS ---"
Q "SHOW TRIGGERS;"
echo "--- 再插一条，看 marker ---"
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(4000, 4.5);"
sleep 3
for h in "${DN[@]}"; do
  echo "  [$h] $(ssh -n -o BatchMode=yes root@$h "cat /tmp/mdskill_trg.log 2>/dev/null | tr '\n' '; '")"
done

echo "##### 6) 清理 #####"
Q "DROP TRIGGER trg_md_probe;"
Q "DROP FUNCTION md_double;"
Q "DROP FUNCTION md_boom;"
Q "DROP DATABASE $DB;"
echo "--- DROP 后 SHOW ---"
Q "SHOW TRIGGERS;"
Q "SHOW FUNCTIONS;" | grep -ci md_double
