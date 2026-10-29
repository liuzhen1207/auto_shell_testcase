#!/bin/bash
# 判别：树模型"只授 WRITE 也能读"是不是真的、是否按路径生效、换个 DN 是否一样
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QU(){ local h=${4:-$QDN}; timeout 120 "$CLI" -h "$h" -u "$1" -pw "$2" -timeout 60 -e "$3" 2>&1; }
row(){ printf '%s' "$1" | grep -E '^Msg:|^Error:' | head -1 | cut -c1-130; printf '%s' "$1" | grep -E '^\|' | tail -n +2 | head -2 | tr '\n' ' '; }
D1=root.md_pm4; D2=root.md_pm5; U=mdw_pm; PW='MdProbe@123456'

Q "DROP USER $U" >/dev/null 2>&1; Q "DROP DATABASE $D1" >/dev/null 2>&1; Q "DROP DATABASE $D2" >/dev/null 2>&1
for d in $D1 $D2; do
  Q "CREATE DATABASE $d" >/dev/null
  Q "CREATE TIMESERIES $d.d1.s1 INT32" >/dev/null
  Q "INSERT INTO $d.d1(timestamp, s1) VALUES(1700000000000, 42)" >/dev/null
done
Q "CREATE USER $U '$PW'" >/dev/null
Q "GRANT WRITE ON $D1.** TO USER $U" >/dev/null

echo "用户 $U 的权限："; Q "LIST PRIVILEGES OF USER $U;" | grep -E '^\|' | sed 's/^/  /'
echo
echo "1) 有 WRITE 的库($D1) 上 SELECT        : $(row "$(QU "$U" "$PW" "SELECT s1 FROM $D1.d1;")")"
echo "2) 完全没权限的库($D2) 上 SELECT      : $(row "$(QU "$U" "$PW" "SELECT s1 FROM $D2.d1;")")"
echo "3) 有 WRITE 的库上 count(*)           : $(row "$(QU "$U" "$PW" "SELECT count(*) FROM $D1.d1;")")"
echo "4) 有 WRITE 的库上 SHOW TIMESERIES    : $(row "$(QU "$U" "$PW" "SHOW TIMESERIES $D1.**;")")"
echo "5) 换个 DataNode(.78) 上 SELECT       : $(row "$(QU "$U" "$PW" "SELECT s1 FROM $D1.d1;" 192.168.99.78)")"
echo "6) 换个 DataNode(.79) 上 SELECT       : $(row "$(QU "$U" "$PW" "SELECT s1 FROM $D1.d1;" 192.168.99.79)")"
echo
echo "7) 对照：只授 READ 的用户在无权限库上 SELECT："
U2=mdr_pm
Q "DROP USER $U2" >/dev/null 2>&1; Q "CREATE USER $U2 '$PW'" >/dev/null
Q "GRANT READ ON $D1.** TO USER $U2" >/dev/null
echo "   $D1 上: $(row "$(QU "$U2" "$PW" "SELECT s1 FROM $D1.d1;")")"
echo "   $D2 上: $(row "$(QU "$U2" "$PW" "SELECT s1 FROM $D2.d1;")")"
echo
echo "8) 只授 WRITE 的用户能否 DELETE / 改 schema："
echo "   DELETE FROM $D1.d1.**    : $(row "$(QU "$U" "$PW" "DELETE FROM $D1.d1.** WHERE time<=1800000000000;")")"
echo "   CREATE TIMESERIES 新序列 : $(row "$(QU "$U" "$PW" "CREATE TIMESERIES $D1.d1.s9 INT32;")")"
echo
echo "=== 清理 ==="
Q "DROP USER $U" >/dev/null 2>&1; Q "DROP USER $U2" >/dev/null 2>&1
Q "DROP DATABASE $D1" >/dev/null 2>&1; Q "DROP DATABASE $D2" >/dev/null 2>&1
echo done
