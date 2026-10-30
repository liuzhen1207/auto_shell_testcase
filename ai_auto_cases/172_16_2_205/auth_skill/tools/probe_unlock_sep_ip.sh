#!/bin/bash
# 三权分立下：IP 级解锁写法 vs 全局解锁写法
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
R() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -1; }
S() { $CLI -h 172.16.2.2 -p 6667 -u security_admin -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -1; }

echo "=== enable separation ==="
R "set configuration 'enable_separation_of_powers'='true'"
sleep 4
echo -n "root now: "; R "show databases"

S "drop user sep_unl" >/dev/null 2>&1
echo -n "create user -> "; S "create user sep_unl 'Sep_unl@123456'"
echo "=== security_admin 执行解锁 ==="
echo -n " A) alter user sep_unl @ '172.16.2.205' account unlock -> "; S "alter user sep_unl @ '172.16.2.205' account unlock"
echo -n " B) alter user sep_unl @ '10.0.0.9' account unlock       -> "; S "alter user sep_unl @ '10.0.0.9' account unlock"
echo -n " C) alter user sep_unl account unlock                     -> "; S "alter user sep_unl account unlock"
echo "=== 对照：sys_admin 执行 IP 级 ==="
echo -n " D) sys_admin: alter user sep_unl @ '1.2.3.4' unlock      -> "; $CLI -h 172.16.2.2 -p 6667 -u sys_admin -pw 'TimechoDB@2021' -e "alter user sep_unl @ '1.2.3.4' account unlock" 2>&1 | head -1
S "drop user sep_unl" >/dev/null 2>&1

echo "=== restore normal mode ==="
for ip in 172.16.2.26 172.16.2.27 172.16.2.28; do
  ssh -o StrictHostKeyChecking=no root@$ip "f=/data/iotdb/$NEW/conf/iotdb-system.properties; grep -q '^enable_separation_of_powers=' \$f && sed -i 's/^enable_separation_of_powers=.*/enable_separation_of_powers=false/' \$f" 2>/dev/null
done
cd /data2/auto_test/auth_suite && NEW=$NEW nohup setsid bash hard_reset.sh > /tmp/reset_after_unl.log 2>&1 < /dev/null &
echo "reset_started"
