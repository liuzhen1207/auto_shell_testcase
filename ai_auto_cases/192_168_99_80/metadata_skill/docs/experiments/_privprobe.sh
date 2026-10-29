#!/bin/bash
# 权限矩阵侦察：权限值 -> LIST PRIVILEGES 里的名字；路径通配；授予/回收/角色
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QU(){ # 以指定用户登录执行
  timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 60 -e "$3" 2>&1; }
DB=root.md_p03
U=mdp03u; R=mdp03r; PW='MdProbe@123456'

Q "DROP USER $U"; Q "DROP ROLE $R"; Q "DROP DATABASE $DB"
Q "CREATE DATABASE $DB"
Q "CREATE TIMESERIES $DB.d1.s1 INT32"
Q "CREATE TIMESERIES $DB.d1.s2 INT32"
Q "INSERT INTO $DB.d1(timestamp, s1, s2) VALUES(1000, 1, 2)"
Q "CREATE USER $U '$PW'"
Q "CREATE ROLE $R"

echo "##### 1) LIST PRIVILEGES 的输出格式（无权限时） #####"
Q "LIST PRIVILEGES OF USER $U;"

echo "##### 2) 逐个权限值：GRANT -> LIST -> REVOKE #####"
for p in READ WRITE ALL SYSTEM SECURITY AUDIT; do
  echo "--- GRANT $p ON $DB.** TO USER ---"
  Q "GRANT $p ON $DB.** TO USER $U;" | head -2
  echo "    LIST:"
  Q "LIST PRIVILEGES OF USER $U;" | grep -E '^\|' | grep -v '^\| *Path' | grep -vE '^\|[-+ ]+\|$' | sed 's/^/      /'
  echo "    REVOKE $p:"
  Q "REVOKE $p ON $DB.** FROM USER $U;" | head -2
  echo "    LIST after revoke:"
  Q "LIST PRIVILEGES OF USER $U;" | grep -cE '^\|' | sed 's/^/      rows=/'
done

echo "##### 3) 多权限一次授予 + WITH GRANT OPTION #####"
Q "GRANT READ, WRITE ON $DB.** TO USER $U WITH GRANT OPTION;" | head -2
Q "LIST PRIVILEGES OF USER $U;"
Q "REVOKE READ, WRITE ON $DB.** FROM USER $U;" | head -2

echo "##### 4) 路径粒度 #####"
Q "GRANT READ ON $DB.d1.s1 TO USER $U;" | head -1
Q "LIST PRIVILEGES OF USER $U;" | grep -E '^\|' | sed 's/^/  /'
Q "REVOKE READ ON $DB.d1.s1 FROM USER $U;" | head -1
Q "GRANT READ ON root.** TO USER $U;" | head -1
Q "LIST PRIVILEGES OF USER $U;" | grep -E '^\|' | sed 's/^/  /'
Q "REVOKE READ ON root.** FROM USER $U;" | head -1

echo "##### 5) 角色侧 #####"
Q "GRANT READ ON $DB.** TO ROLE $R;" | head -1
Q "LIST PRIVILEGES OF ROLE $R;" | grep -E '^\|' | sed 's/^/  /'
Q "GRANT ROLE $R TO $U;" | head -1
echo "  LIST ROLE OF USER: $(Q "LIST ROLE OF USER $U;" | grep -c "$R")"
echo "  授予角色后 LIST PRIVILEGES OF USER 是否含角色权限:"
Q "LIST PRIVILEGES OF USER $U;" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' | sed 's/^/    /'

echo "##### 6) 权限真的生效吗（以用户身份执行） #####"
echo "--- 只有 READ 时 ---"
Q "REVOKE ROLE $R FROM $U;" | head -1
Q "GRANT READ ON $DB.** TO USER $U;" | head -1
echo "  SELECT:  $(QU "$U" "$PW" "SELECT s1 FROM $DB.d1;" | tail -3 | head -2 | tr '\n' ' ')"
echo "  INSERT:  $(QU "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(2000, 9);" | head -2 | tr '\n' ' ')"
echo "--- 加上 WRITE 后 ---"
Q "GRANT WRITE ON $DB.** TO USER $U;" | head -1
echo "  INSERT:  $(QU "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(3000, 9);" | head -2 | tr '\n' ' ')"
echo "--- 只有角色、没有直接权限时 ---"
Q "REVOKE READ ON $DB.** FROM USER $U;" | head -1
Q "REVOKE WRITE ON $DB.** FROM USER $U;" | head -1
Q "GRANT ROLE $R TO $U;" | head -1
echo "  SELECT:  $(QU "$U" "$PW" "SELECT s1 FROM $DB.d1;" | tail -3 | head -2 | tr '\n' ' ')"

echo "##### 7) 清理 #####"
Q "REVOKE ROLE $R FROM $U"
Q "DROP USER $U"
Q "DROP ROLE $R"
Q "DROP DATABASE $DB"
