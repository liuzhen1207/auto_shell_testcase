#!/bin/bash
# 补充实验：把"多路径删除"的各种写法测全，便于研发精确复现
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
QT(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -sql_dialect table -timeout 60 -e "$1" 2>&1; }
A=root.md_dpy_a; B=root.md_dpy_b; N=root.md_dpy_none
mk(){ Q "DROP DATABASE $A" >/dev/null 2>&1; Q "DROP DATABASE $B" >/dev/null 2>&1; Q "CREATE DATABASE $A;" >/dev/null; Q "CREATE DATABASE $B;" >/dev/null; }
chk(){ echo "     -> A 存在=$(Q "SHOW DATABASES $A;" | grep -c "$A")  B 存在=$(Q "SHOW DATABASES $B;" | grep -c "$B")"; }

echo "### 1) DROP DATABASE a, <不存在>"
mk; Q "DROP DATABASE $A, $N;"; chk
echo "### 2) DELETE DATABASE a, <不存在>"
mk; Q "DELETE DATABASE $A, $N;"; chk
echo "### 3) DROP STORAGE GROUP a, <不存在>"
mk; Q "DROP STORAGE GROUP $A, $N;"; chk
echo "### 4) DELETE STORAGE GROUP a, <不存在>"
mk; Q "DELETE STORAGE GROUP $A, $N;"; chk
echo "### 5) DROP DATABASE a, b（两个都存在，对照）"
mk; Q "DROP DATABASE $A, $B;"; chk
echo "### 6) DROP DATABASE <不存在>（单路径，对照）"
mk; Q "DROP DATABASE $N;"; chk
echo "### 7) 表模型 DROP DATABASE a, b（逗号列表在表方言是否合法）"
QT "DROP DATABASE nosuchdb_t1, nosuchdb_t2;"
echo "### 8) 多路径里混一个非库路径（设备路径）"
mk; Q "CREATE TIMESERIES ${A}.d1.s1 INT32;" >/dev/null 2>&1
Q "DROP DATABASE $A, ${A}.d1.s1;"; chk
echo "### 9) 重复删除同一个库两次"
mk; Q "DROP DATABASE $A, $A;"; chk
echo "### 10) 版本确认"
Q "SHOW VERSION;"
echo "### 清理"
Q "DROP DATABASE $A" >/dev/null 2>&1; Q "DROP DATABASE $B" >/dev/null 2>&1
echo done
