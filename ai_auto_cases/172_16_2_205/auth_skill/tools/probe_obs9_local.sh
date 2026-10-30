#!/bin/bash
# OBS-9 验证：本机登录的 root 是否豁免锁定（需求 L128）
NEW=v20121rc12_1027_c05111d
for _d in /data2/iotdb /data1/iotdb /data/iotdb; do [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break; done
echo "CLI=$CLI"
DN2=172.16.2.2

echo "=== 0) 基线 ==="
$CLI -h 127.0.0.1 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2

echo
echo "=== A) 本机 127.0.0.1：连续 8 次错误后，用正确密码登录 ==="
for i in $(seq 1 8); do
  $CLI -h 127.0.0.1 -p 6667 -u root -pw "BadLocal@1" -e "show cluster" >/dev/null 2>&1
done
echo -n "  正确密码(127.0.0.1) -> "; $CLI -h 127.0.0.1 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2

echo
echo "=== B) 本机 IP 172.16.2.2：连续 8 次错误后，用正确密码登录 ==="
for i in $(seq 1 8); do
  $CLI -h $DN2 -p 6667 -u root -pw "BadLocal@2" -e "show cluster" >/dev/null 2>&1
done
echo -n "  正确密码(172.16.2.2) -> "; $CLI -h $DN2 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2

echo
echo "=== C) 远程 205：连续 6 次错误后，用正确密码登录（应与本机不同） ==="
for i in $(seq 1 6); do
  $CLI -h $DN2 -p 6667 -u root -pw "BadRemote@1" -e "show cluster" >/dev/null 2>&1
done
echo -n "  正确密码(远程) -> "; $CLI -h $DN2 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2

echo
echo "=== D) 远程锁定后，本机再试（判断锁是用户级还是 用户@IP 级） ==="
echo -n "  本机 127.0.0.1 -> "; $CLI -h 127.0.0.1 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2
echo -n "  本机 172.16.2.2 -> "; $CLI -h $DN2 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -2
