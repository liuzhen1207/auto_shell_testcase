#!/bin/bash
# 确认 UNLOCK 的语法变体（normal 模式，root 身份）
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
R() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -2; }
R "drop user unltest" >/dev/null 2>&1
R "create user unltest 'Unltest@12345'" | head -1
echo "=== 各种写法 ==="
echo -n "1) ALTER USER unltest ACCOUNT UNLOCK            -> "; R "alter user unltest account unlock"
echo -n "2) ALTER USER unltest@'172.16.2.205' UNLOCK     -> "; R "alter user unltest@'172.16.2.205' account unlock"
echo -n '3) ALTER USER unltest@"172.16.2.205" UNLOCK     -> '; R 'alter user unltest@"172.16.2.205" account unlock'
echo -n "4) ALTER USER unltest@172.16.2.205 UNLOCK       -> "; R "alter user unltest@172.16.2.205 account unlock"
echo -n "5) table 方言 1)                                -> "; $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "alter user unltest account unlock" 2>&1 | head -2
echo "=== 清理 ==="
R "drop user unltest" >/dev/null 2>&1
