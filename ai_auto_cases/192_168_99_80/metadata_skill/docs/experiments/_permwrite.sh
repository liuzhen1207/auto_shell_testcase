#!/bin/bash
# 复核：树模型"只授 WRITE 的用户能不能读"（完整原始输出，不截断）
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QU(){ timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 60 -e "$3" 2>&1; }
DB=root.md_perm2
U1=mdu_ro      # 只 READ
U2=mdu_wo      # 只 WRITE
U3=mdu_none    # 无权限
PW='MdProbe@123456'

for u in $U1 $U2 $U3; do Q "DROP USER $u" >/dev/null 2>&1; done
Q "DROP DATABASE $DB" >/dev/null 2>&1
Q "CREATE DATABASE $DB" >/dev/null
Q "CREATE TIMESERIES $DB.d1.s1 INT32" >/dev/null
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(1700000000000, 42)" >/dev/null
for u in $U1 $U2 $U3; do Q "CREATE USER $u '$PW'" >/dev/null; done
Q "GRANT READ  ON $DB.** TO USER $U1" >/dev/null
Q "GRANT WRITE ON $DB.** TO USER $U2" >/dev/null

show(){
  echo "=========== $1 ==========="
  echo "--- LIST PRIVILEGES OF USER $2 ---"
  Q "LIST PRIVILEGES OF USER $2;"
  echo "--- 以该用户 SELECT s1 FROM $DB.d1 ---"
  QU "$2" "$PW" "SELECT s1 FROM $DB.d1;"
  echo "--- 以该用户 INSERT ---"
  QU "$2" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(1800000000000, 7);"
  echo
}
show "用户A：只授 READ"  "$U1"
show "用户B：只授 WRITE" "$U2"
show "用户C：零权限"     "$U3"

echo "=========== 交叉验证：换个全新的库/序列，只授 WRITE 的新用户 ==========="
DB2=root.md_perm3
U4=mdu_wo2
Q "DROP USER $U4" >/dev/null 2>&1; Q "DROP DATABASE $DB2" >/dev/null 2>&1
Q "CREATE DATABASE $DB2" >/dev/null
Q "CREATE TIMESERIES $DB2.d1.s1 INT32" >/dev/null
Q "INSERT INTO $DB2.d1(timestamp, s1) VALUES(1700000000000, 99)" >/dev/null
Q "CREATE USER $U4 '$PW'" >/dev/null
Q "GRANT WRITE ON $DB2.d1.** TO USER $U4" >/dev/null
echo "--- LIST PRIVILEGES OF USER $U4 ---"; Q "LIST PRIVILEGES OF USER $U4;"
echo "--- SELECT（只授 WRITE，且只授到设备级 d1.**）---"; QU "$U4" "$PW" "SELECT s1 FROM $DB2.d1;"
echo "--- SELECT count(*) ---"; QU "$U4" "$PW" "SELECT count(*) FROM $DB2.d1;"
echo "--- SHOW TIMESERIES（元数据可见性）---"; QU "$U4" "$PW" "SHOW TIMESERIES $DB2.**;"
echo
echo "=== 清理 ==="
for u in $U1 $U2 $U3 $U4; do Q "DROP USER $u" >/dev/null 2>&1; done
Q "DROP DATABASE $DB" >/dev/null 2>&1; Q "DROP DATABASE $DB2" >/dev/null 2>&1
echo done
