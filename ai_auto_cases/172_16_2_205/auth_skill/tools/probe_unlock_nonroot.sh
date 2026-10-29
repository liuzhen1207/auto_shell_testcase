#!/bin/bash
# normal 模式下：让一个拥有 SECURITY 权限的普通用户执行 UNLOCK，看是否同样 701
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
R() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -2; }
S() { $CLI -h 172.16.2.2 -p 6667 -u sec_exec -pw 'Sec@123456789' -e "$1" 2>&1 | head -2; }

echo "=== 前置：建被解锁用户 + 建执行者 ==="
R "drop user unl_target" >/dev/null 2>&1; R "drop user sec_exec" >/dev/null 2>&1
R "create user unl_target 'Unl@123456789'" | head -1
R "create user sec_exec 'Sec@123456789'" | head -1
echo "=== 给执行者授 SECURITY（尝试两种语法） ==="
echo -n "  grant security on root.** -> "; R "grant security on root.** to user sec_exec"
echo -n "  grant security to user     -> "; R "grant security to user sec_exec"
sleep 2
echo "=== 执行者权限 ==="
R "list privileges of user sec_exec" | head -8
echo "=== 非 root 执行 UNLOCK ==="
echo -n "  sec_exec: alter user unl_target account unlock -> "; S "alter user unl_target account unlock"
echo "=== root 对照 ==="
echo -n "  root: alter user unl_target account unlock   -> "; R "alter user unl_target account unlock"
echo "=== 清理 ==="
R "drop user unl_target" >/dev/null 2>&1; R "drop user sec_exec" >/dev/null 2>&1
