#!/bin/bash
NEW=v20131rc2_1110_83183d0
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
Q() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
T() { timeout 40 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }

echo "=== 1) show configuration 规模 ==="
Q "show configuration" > /tmp/cfgdump.txt 2>&1
echo "  行数: $(wc -l < /tmp/cfgdump.txt)"
echo "  前 4 行:"; head -4 /tmp/cfgdump.txt
echo "=== 2) 是否含 enforce_strong_password ==="
grep -i "strong_password" /tmp/cfgdump.txt || echo "  (未找到)"
echo "=== 3) 树方言是否支持 ==="
T "show configuration" | head -2
echo "=== 4) 热变更是否反映 ==="
T "SET CONFIGURATION 'enforce_strong_password'='false'" | head -1
sleep 3
grep -i "strong_password" /tmp/cfgdump.txt >/dev/null
Q "show configuration" | grep -i "strong_password"
echo "=== 5) 恢复 true 后再看 ==="
T "SET CONFIGURATION 'enforce_strong_password'='true'" | head -1
sleep 3
Q "show configuration" | grep -i "strong_password"
echo "=== 6) 过滤写法 ==="
echo -n "  show configuration 'enforce_strong_password': "; Q "show configuration 'enforce_strong_password'" | head -3 | tr '\n' ' '; echo
echo -n "  show configuration like '%password%': "; Q "show configuration like '%password%'" | head -3 | tr '\n' ' '; echo
echo "=== 7) 与 show variables 对比 ==="
echo -n "  show variables 行数: "; Q "show variables" | wc -l
echo -n "  show configuration 行数: "; Q "show configuration" | wc -l
