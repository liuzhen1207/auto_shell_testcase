#!/bin/bash
NEW=v20121rc12_1027_c05111d
echo "=== 配置文件阈值核对 ==="
for ip in 172.16.2.26 172.16.2.27 172.16.2.28; do
  echo -n "  CN $ip: "
  ssh -o StrictHostKeyChecking=no root@$ip "grep -E '^failed_login_attempts' /data/iotdb/$NEW/conf/iotdb-system.properties 2>/dev/null | tr '\n' ' '" 2>/dev/null; echo
done
for ip in 172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6; do
  echo -n "  DN $ip: "
  ssh -o StrictHostKeyChecking=no root@$ip "grep -E '^failed_login_attempts' /data1/iotdb/$NEW/conf/iotdb-system.properties 2>/dev/null | tr '\n' ' '" 2>/dev/null; echo
done
echo
echo "=== 残留测试用户检查 ==="
/data2/iotdb/$NEW/sbin/start-cli.sh -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "list user" 2>&1 | head -8
echo
echo "=== 健康检查用例 ==="
cd /data2/auto_test/auth_suite && bash tools/suite_auth.sh AUTH-001 AUTH-017 2>&1 | tail -6
