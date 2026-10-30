#!/bin/bash
# Q2 补测：三权分立下 security_admin 的“本机豁免”是否生效
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
DN2=172.16.2.2
R() { $CLI -h $DN2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1 | head -1; }
REMOTE() { $CLI -h $DN2 -p 6667 -u security_admin -pw "$1" -e "list user" 2>&1 | head -1; }
LOCAL() {  # 在 DN 主机本地执行，参数为密码
  ssh -o StrictHostKeyChecking=no root@$DN2 "bash -s -- '$NEW' '$DN2' '$1'" <<'EOS'
NEW="$1"; IP="$2"; PW="$3"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
$CLI -h "$IP" -p 6667 -u security_admin -pw "$PW" -e "list user" 2>&1 | head -1
EOS
}
LOCALWRONG() {  # 本机连续 N 次错误
  ssh -o StrictHostKeyChecking=no root@$DN2 "bash -s -- '$NEW' '$DN2' '$1'" <<'EOS'
NEW="$1"; IP="$2"; N="${3:-8}"
for _d in /data1/iotdb /data2/iotdb /data/iotdb; do
  [ -x "$_d/$NEW/sbin/start-cli.sh" ] && CLI="$_d/$NEW/sbin/start-cli.sh" && break
done
for i in $(seq 1 "$N"); do $CLI -h "$IP" -p 6667 -u security_admin -pw "WrongLocal@9" -e "list user" >/dev/null 2>&1; done
echo done
EOS
}

echo "=== 0) 开启三权分立 ==="
R "set configuration 'enable_separation_of_powers'='true'"
sleep 5
echo -n "  root 现在: "; R "list user"

echo "=== 1) 基线：security_admin 远程登录 ==="
echo -n "  远程 -> "; REMOTE 'TimechoDB@2021'

echo "=== 2) 本机连续 8 次错误后，本机用正确密码 ==="
LOCALWRONG 'x' >/dev/null 2>&1
echo -n "  本机 -> "; LOCAL 'TimechoDB@2021'

echo "=== 3) 远程连续 6 次错误后，远程用正确密码（预期被锁） ==="
for i in $(seq 1 6); do REMOTE 'WrongRemote@9' >/dev/null 2>&1; done
echo -n "  远程 -> "; REMOTE 'TimechoDB@2021'

echo "=== 4) 远程锁定后，本机再用正确密码（豁免是否优先于锁定） ==="
echo -n "  本机 -> "; LOCAL 'TimechoDB@2021'
