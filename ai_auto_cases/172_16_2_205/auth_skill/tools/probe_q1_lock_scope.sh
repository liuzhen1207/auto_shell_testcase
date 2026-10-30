#!/bin/bash
# Q1 关键判定：锁定是 用户 级还是 用户@IP 级 —— 换来源 IP 是否仍可登录
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
TARGET=172.16.2.2

echo "=== 1) 先确保无锁：清 DN 2.2 ==="
ssh -o StrictHostKeyChecking=no root@$TARGET "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh >/dev/null 2>&1; sleep 2; pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 3" 2>/dev/null
ssh -o StrictHostKeyChecking=no root@$TARGET "setsid /data1/iotdb/$NEW/sbin/start-datanode.sh >> /tmp/dn_q1.log 2>&1 < /dev/null &" 2>/dev/null
for i in $(seq 1 40); do
  n=$($CLI -h $TARGET -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>/dev/null | grep -c Running)
  [ "${n:-0}" -ge 8 ] && { echo "  ready($i)"; break; }
  sleep 5
done

echo "=== 2) 从 205 连续 6 次错误锁定 root ==="
for i in $(seq 1 6); do $CLI -h $TARGET -p 6667 -u root -pw "Wrong@$i" -e "show cluster" >/dev/null 2>&1; done
echo -n "  205 正确密码 -> "; $CLI -h $TARGET -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -1

echo "=== 3) 换来源：从 DN 172.16.2.3 发起 root 登录 ==="
ssh -o StrictHostKeyChecking=no root@172.16.2.3 "bash -s -- '$NEW' '$TARGET'" <<'EOS'
NEW="$1"; IP="$2"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
echo -n "  172.16.2.3 发起 -> "; $CLI -h "$IP" -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -1
EOS

echo "=== 4) 从 205 换目标 DN（.3）登录 ==="
echo -n "  205 -> .3 -> "; $CLI -h 172.16.2.3 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -1
