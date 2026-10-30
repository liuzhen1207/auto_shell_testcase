#!/bin/bash
# 全局（用户级）锁验证——改用 DN .3 作为目标，避开 .2 上 205 来源的残留锁
NEW=v20121rc12_1027_c05111d
CLI205=/data2/iotdb/$NEW/sbin/start-cli.sh
T=172.16.2.3

A() { ssh -o StrictHostKeyChecking=no root@$T "bash -s -- '$NEW' '$T' '$1'" <<'EOS'
NEW="$1"; IP="$2"; SQL="$3"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
$CLI -h "$IP" -p 6667 -u root -pw 'TimechoDB@2021' -e "$SQL" 2>&1 | head -2
EOS
}
W() { $CLI205 -h $T -p 6667 -u lockglobal -pw "$1" -e "show cluster" 2>&1 | head -1; }

echo "=== 0) 阈值现状（admin 在 .3 本机执行） ==="
A "show configuration 'failed_login_attempts'"
A "show configuration 'failed_login_attempts_per_user'"

echo "=== 1) 建用户 + 用户级阈值调为 3 ==="
A "drop user lockglobal" >/dev/null 2>&1
A "create user lockglobal 'Lockglobal@123'"
A "set configuration 'failed_login_attempts_per_user'='3'"
sleep 3
A "show configuration 'failed_login_attempts_per_user'"

echo "=== 2) 从 205 连续 3 次错误（IP 级 5 未到 / 用户级 3 到） ==="
for i in 1 2 3; do W "Wrong@$i" >/dev/null 2>&1; done
echo -n "  来源 205 -> "; W 'Lockglobal@123'

echo "=== 3) 换来源 IP：从 .3 本机发起 ==="
echo -n "  来源 .3  -> "; A "select count(*) from root.**" >/dev/null 2>&1
ssh -o StrictHostKeyChecking=no root@$T "bash -s -- '$NEW' '$T'" <<'EOS'
NEW="$1"; IP="$2"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
$CLI -h "$IP" -p 6667 -u lockglobal -pw 'Lockglobal@123' -e "show cluster" 2>&1 | head -1
EOS

echo "=== 4) 清理 ==="
A "set configuration 'failed_login_attempts_per_user'='1000'"
sleep 2
A "show configuration 'failed_login_attempts_per_user'"
A "drop user lockglobal" >/dev/null 2>&1
echo done
