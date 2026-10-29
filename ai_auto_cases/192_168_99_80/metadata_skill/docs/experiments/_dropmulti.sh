#!/bin/bash
# 复现/否证：DROP DATABASE a, b（b 不存在）到底什么行为
# 关键：打印**完整原始输出**，并逐条检查删除后的实际状态
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
A=root.md_dpx_a
B=root.md_dpx_b
N=root.md_dpx_none

exists(){ Q "SHOW DATABASES $1;" | md_count "$(cat)"; }

echo "##### 准备：建 A、B，确保 N 不存在 #####"
Q "DROP DATABASE $A" >/dev/null 2>&1
Q "DROP DATABASE $B" >/dev/null 2>&1
Q "DROP DATABASE $N" >/dev/null 2>&1
Q "CREATE DATABASE $A;"
Q "CREATE DATABASE $B;"
echo "A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")   B 存在? $(Q "SHOW DATABASES $B;" | grep -c "$B")   N 存在? $(Q "SHOW DATABASES $N;" | grep -c "$N")"

echo
echo "##### V1: 单路径删不存在的库（对照） #####"
echo "--- 命令: DROP DATABASE $N;"
Q "DROP DATABASE $N;"
echo "--- 状态: N 存在? $(Q "SHOW DATABASES $N;" | grep -c "$N")"

echo
echo "##### V2: 多路径，第一个存在、第二个不存在 #####"
echo "--- 命令: DROP DATABASE $A, $N;"
Q "DROP DATABASE $A, $N;"
echo "--- 状态: A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")"

echo
echo "##### V3: 重建 A，多路径把不存在的放前面 #####"
Q "CREATE DATABASE $A;"
echo "--- 命令: DROP DATABASE $N, $A;"
Q "DROP DATABASE $N, $A;"
echo "--- 状态: A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")"

echo
echo "##### V4: 重建 A，多路径都存在的对照 #####"
Q "CREATE DATABASE $A;"
echo "--- 命令: DROP DATABASE $A, $B;"
Q "DROP DATABASE $A, $B;"
echo "--- 状态: A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")   B 存在? $(Q "SHOW DATABASES $B;" | grep -c "$B")"

echo
echo "##### V5: 无空格写法 #####"
Q "CREATE DATABASE $A;"
echo "--- 命令: DROP DATABASE $A,$N;"
Q "DROP DATABASE $A,$N;"
echo "--- 状态: A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")"

echo
echo "##### V6: 三个路径，中间那个不存在 #####"
Q "CREATE DATABASE $A;"
Q "CREATE DATABASE $B;"
echo "--- 命令: DROP DATABASE $A, $N, $B;"
Q "DROP DATABASE $A, $N, $B;"
echo "--- 状态: A 存在? $(Q "SHOW DATABASES $A;" | grep -c "$A")   B 存在? $(Q "SHOW DATABASES $B;" | grep -c "$B")"

echo
echo "##### 清理 #####"
Q "DROP DATABASE $A" >/dev/null 2>&1
Q "DROP DATABASE $B" >/dev/null 2>&1
Q "DROP DATABASE $N" >/dev/null 2>&1
echo "done"
