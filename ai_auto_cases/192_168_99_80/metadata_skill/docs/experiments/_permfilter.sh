#!/bin/bash
# 树模型"读是按权限过滤"的演示：只授 db1 的 READ，查 root.** 应只看到 db1 的数据
# 对照：表模型只授 db1 的 SELECT，查 db2 直接 803
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QT(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 60 -e "$1" 2>&1; }
QU(){ timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 60 -e "$3" 2>&1; }
QUT(){ timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -sql_dialect table -timeout 60 -e "$3" 2>&1; }
A=root.md_flt1; B=root.md_flt2; U=mdr_flt; PW='MdProbe@123456'
TA=md_flt1; TB=md_flt2; UM=mdr_fltt

Q "DROP USER $U" >/dev/null 2>&1; Q "DROP DATABASE $A" >/dev/null 2>&1; Q "DROP DATABASE $B" >/dev/null 2>&1
for d in $A $B; do
  Q "CREATE DATABASE $d" >/dev/null
  Q "CREATE TIMESERIES $d.d1.s1 INT32" >/dev/null
  Q "INSERT INTO $d.d1(timestamp, s1) VALUES(1700000000000, 1)" >/dev/null
done
echo "root 视角：$A 有 1 行，$B 有 1 行"
Q "CREATE USER $U '$PW'" >/dev/null
Q "GRANT READ ON $A.** TO USER $U" >/dev/null

echo
echo "=== 树模型：只授 $A 的 READ ==="
echo "--- SELECT s1 FROM $A.d1（有权限）---"
QU "$U" "$PW" "SELECT s1 FROM $A.d1;"
echo "--- SELECT s1 FROM $B.d1（无权限，同一条语句里换库）---"
QU "$U" "$PW" "SELECT s1 FROM $B.d1;"
echo "--- 一条语句同时查两个库（应只返回有权限那个）---"
QU "$U" "$PW" "SELECT s1 FROM $A.d1, $B.d1;"
echo "--- SELECT * FROM root.**（全库扫描，应只出现 $A 的列）---"
QU "$U" "$PW" "SELECT * FROM root.**;"

echo
echo "=== 表模型对照：只授 $TA 的 SELECT ==="
for d in $TA $TB; do QT "DROP DATABASE IF EXISTS $d" >/dev/null 2>&1; QT "CREATE DATABASE $d" >/dev/null; QT "CREATE TABLE $d.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD)" >/dev/null; QT "INSERT INTO $d.t1 (time, dev, m1) VALUES (1700000000000, 'd1', 1)" >/dev/null; done
QT "DROP USER $UM" >/dev/null 2>&1; QT "CREATE USER $UM '$PW'" >/dev/null
QT "GRANT SELECT ON DATABASE $TA TO USER $UM" >/dev/null
echo "--- SELECT FROM $TA.t1（有权限）---"; QUT "$UM" "$PW" "SELECT m1 FROM $TA.t1;"
echo "--- SELECT FROM $TB.t1（无权限）---";     QUT "$UM" "$PW" "SELECT m1 FROM $TB.t1;"

echo
echo "=== 清理 ==="
Q "DROP USER $U" >/dev/null 2>&1; Q "DROP DATABASE $A" >/dev/null 2>&1; Q "DROP DATABASE $B" >/dev/null 2>&1
QT "DROP USER $UM" >/dev/null 2>&1; QT "DROP DATABASE IF EXISTS $TA" >/dev/null 2>&1; QT "DROP DATABASE IF EXISTS $TB" >/dev/null 2>&1
echo done
