#!/bin/bash
# 权限越权行为：树模型 vs 表模型 × {零权限 / 只读 / 只写} × {SELECT / 写}
# 目的：把"读被静默过滤、写报 803"这句话的前提补齐，给出可复现的例子
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QT(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 60 -e "$1" 2>&1; }
QU(){ timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 60 -e "$3" 2>&1; }
QUT(){ timeout 120 "$CLI" -h "$QDN" -u "$1" -pw "$2" -sql_dialect table -timeout 60 -e "$3" 2>&1; }
brief(){ printf '%s' "$1" | grep -E '^(Msg:|Error:)' | head -1 | cut -c1-150; [ -z "$(printf '%s' "$1" | grep -E '^(Msg:|Error:)')" ] && printf '%s' "$1" | grep -E '^\|' | tail -n +2 | head -3 | tr '\n' ' '; }
TDB=root.md_perm
MDB=md_perm_t
UT=mdu_perm_t
UM=mdu_perm_m
PW='MdProbe@123456'
TS=1700000000000

echo "############ 树模型 ############"
Q "DROP USER $UT" >/dev/null 2>&1; Q "DROP DATABASE $TDB" >/dev/null 2>&1
Q "CREATE DATABASE $TDB" >/dev/null
Q "CREATE TIMESERIES $TDB.d1.s1 INT32" >/dev/null
Q "INSERT INTO $TDB.d1(timestamp, s1) VALUES($TS, 42)" >/dev/null
Q "CREATE USER $UT '$PW'" >/dev/null
echo "数据（root 视角）: $(brief "$(Q "SELECT s1 FROM $TDB.d1;")")"

stage(){
  echo "--- [$1] LIST PRIVILEGES: $(Q "LIST PRIVILEGES OF USER $UT;" | md_count "$(cat)") 行"
  echo "    SELECT : $(brief "$(QU "$UT" "$PW" "SELECT s1 FROM $TDB.d1;")")"
  echo "    INSERT : $(brief "$(QU "$UT" "$PW" "INSERT INTO $TDB.d1(timestamp, s1) VALUES(1800000000000, 7);")")"
}
stage "零权限"
Q "GRANT READ ON $TDB.** TO USER $UT" >/dev/null; stage "只授 READ"
Q "REVOKE READ ON $TDB.** FROM USER $UT" >/dev/null
Q "GRANT WRITE ON $TDB.** TO USER $UT" >/dev/null; stage "只授 WRITE"
Q "REVOKE WRITE ON $TDB.** FROM USER $UT" >/dev/null

echo
echo "############ 表模型 ############"
QT "DROP USER $UM" >/dev/null 2>&1
QT "DROP DATABASE IF EXISTS $MDB" >/dev/null 2>&1
QT "CREATE DATABASE $MDB" >/dev/null
QT "CREATE TABLE $MDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD)" >/dev/null
QT "INSERT INTO $MDB.t1 (time, dev, m1) VALUES ($TS, 'd1', 42)" >/dev/null
QT "CREATE USER $UM '$PW'" >/dev/null
echo "数据（root 视角）: $(brief "$(QT "SELECT m1 FROM $MDB.t1;")")"
echo "授权语法（表模型）: GRANT <SELECT|INSERT|CREATE|DROP|ALTER|DELETE|ALL> ON DATABASE|TABLE <名> TO USER u"

stage_t(){
  echo "--- [$1] LIST PRIVILEGES:"
  QT "LIST PRIVILEGES OF USER $UM;" | grep -E '^\|' | sed 's/^/      /'
  echo "    SELECT : $(brief "$(QUT "$UM" "$PW" "SELECT m1 FROM $MDB.t1;")")"
  echo "    INSERT : $(brief "$(QUT "$UM" "$PW" "INSERT INTO $MDB.t1 (time, dev, m1) VALUES (1800000000000, 'd1', 7);")")"
}
stage_t "零权限"
echo "    (GRANT SELECT ON DATABASE $MDB TO USER $UM)"
QT "GRANT SELECT ON DATABASE $MDB TO USER $UM" | head -1
stage_t "只授 SELECT"
QT "REVOKE SELECT ON DATABASE $MDB FROM USER $UM" | head -1
echo "    (GRANT INSERT ON DATABASE $MDB TO USER $UM)"
QT "GRANT INSERT ON DATABASE $MDB TO USER $UM" | head -1
stage_t "只授 INSERT"
QT "REVOKE INSERT ON DATABASE $MDB FROM USER $UM" | head -1

echo
echo "############ 清理 ############"
Q "DROP USER $UT" >/dev/null 2>&1; Q "DROP DATABASE $TDB" >/dev/null 2>&1
QT "DROP USER $UM" >/dev/null 2>&1; QT "DROP DATABASE IF EXISTS $MDB" >/dev/null 2>&1
echo done
