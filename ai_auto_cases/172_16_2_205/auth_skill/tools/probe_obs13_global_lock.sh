#!/bin/bash
# OBS-13 专项：验证「用户级全局锁」——启动前把 failed_login_attempts_per_user 改小
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
CN="172.16.2.26 172.16.2.27 172.16.2.28"
DN="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
T=172.16.2.2

set_cfg() {
  local v=$1 ip f
  for ip in $CN; do
    ssh -o StrictHostKeyChecking=no root@$ip "f=/data/iotdb/$NEW/conf/iotdb-system.properties; touch \$f; sed -i '/^failed_login_attempts_per_user=/d' \$f; echo 'failed_login_attempts_per_user=$v' >> \$f" 2>/dev/null
  done
  for ip in $DN; do
    ssh -o StrictHostKeyChecking=no root@$ip "f=/data1/iotdb/$NEW/conf/iotdb-system.properties; touch \$f; sed -i '/^failed_login_attempts_per_user=/d' \$f; echo 'failed_login_attempts_per_user=$v' >> \$f" 2>/dev/null
  done
  echo "  配置已写入: failed_login_attempts_per_user=$v"
}
restart_cluster() {
  ( cd /data2/auto_test/auth_suite && NEW=$NEW bash tools/hard_reset.sh ) 2>&1 | tail -2
}
from_host() {  # ip sql user pw
  ssh -o StrictHostKeyChecking=no root@$1 "bash -s -- '$NEW' '$T' '$3' '$4' '$2'" <<'EOS'
NEW="$1"; T="$2"; U="$3"; PW="$4"; SQL="$5"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
$CLI -h "$T" -p 6667 -u "$U" -pw "$PW" -e "$SQL" 2>&1 | head -1
EOS
}

echo "=== 1) 改小阈值（3）并重启集群（启动前生效） ==="
set_cfg 3
restart_cluster
echo -n "  集群就绪检查: "; $CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>/dev/null | grep -c Running

echo "=== 2) 建测试用户（root） ==="
$CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "drop user lockglobal" >/dev/null 2>&1
$CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "create user lockglobal 'Lockglobal@123'" 2>&1 | head -1

echo "=== 3) 两个不同来源各错几次（合计 3，单 IP 均未到 5） ==="
echo "  205 错 2 次"; for i in 1 2; do $CLI -h $T -p 6667 -u lockglobal -pw "Wrong@$i" -e "show cluster" >/dev/null 2>&1; done
echo "  .3 错 1 次（累计 3，达用户级阈值）"; from_host 172.16.2.3 "show cluster" lockglobal 'Wrong@3'
echo -n "  205 用正确密码 -> "; $CLI -h $T -p 6667 -u lockglobal -pw 'Lockglobal@123' -e "show cluster" 2>&1 | head -1
echo -n "  .4 用正确密码（全新来源，验证是否全局） -> "; from_host 172.16.2.4 "show cluster" lockglobal 'Lockglobal@123'

echo "=== 4) root 手动解锁后，.4 再登录 ==="
$CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "alter user lockglobal account unlock" 2>&1 | head -1
sleep 2
echo -n "  .4 -> "; from_host 172.16.2.4 "show cluster" lockglobal 'Lockglobal@123'

echo "=== 5) 还原阈值 1000 并重启 ==="
$CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "drop user lockglobal" >/dev/null 2>&1
set_cfg 1000
restart_cluster
echo -n "  还原后就绪: "; $CLI -h $T -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>/dev/null | grep -c Running
echo "OBS-13 done"
