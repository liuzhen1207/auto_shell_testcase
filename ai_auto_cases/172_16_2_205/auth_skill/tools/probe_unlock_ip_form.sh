#!/bin/bash
# 按 TC-01652 的写法（@ 两边带空格）验证 IP 级解锁语法
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
R() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -2; }
R "drop user unltest2" >/dev/null 2>&1
R "create user unltest2 'Unltest@123456'" | head -1
echo "=== TC-01652 写法（带空格） ==="
echo -n "1) alter user unltest2 @ '172.16.2.205' account unlock -> "; R "alter user unltest2 @ '172.16.2.205' account unlock"
echo -n "2) alter user unltest2 @ '192.168.1.1' account unlock   -> "; R "alter user unltest2 @ '192.168.1.1' account unlock"
echo -n "3) alter user unltest2 account unlock                    -> "; R "alter user unltest2 account unlock"
R "drop user unltest2" >/dev/null 2>&1
echo done
