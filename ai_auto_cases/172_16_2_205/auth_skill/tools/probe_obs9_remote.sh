#!/bin/bash
# OBS-9 判定：远程锁定 vs 本机豁免
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
LOGIN=(-h 172.16.2.2 -p 6667 -u root)

echo "=== 1) 先清锁：重启 DN 2.2 ==="
ssh -o StrictHostKeyChecking=no root@172.16.2.2 "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh >/dev/null 2>&1; sleep 2; pkill -9 -f 'com.timecho.iotdb.DataNode'; sleep 3" 2>/dev/null
ssh -o StrictHostKeyChecking=no root@172.16.2.2 "setsid /data1/iotdb/$NEW/sbin/start-datanode.sh >> /tmp/dn_obs9.log 2>&1 < /dev/null &" 2>/dev/null
for i in $(seq 1 40); do
  n=$($CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster;" 2>/dev/null | grep -c Running)
  [ "${n:-0}" -ge 8 ] && { echo "  ready ($i)"; break; }
  sleep 5
done

echo "=== 2) 远程(205) root 连续 6 次错误 ==="
for i in $(seq 1 6); do $CLI "${LOGIN[@]}" -pw "Wrong@$i" -e "show cluster" >/dev/null 2>&1; done
echo -n "  远程正确密码 -> "; $CLI "${LOGIN[@]}" -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -1

echo "=== 3) 此时本机(2.2) root 正确密码 ==="
ssh -o StrictHostKeyChecking=no root@172.16.2.2 "bash -s" <<'EOS'
NEW=v20121rc12_1027_c05111d
CLI=/data1/iotdb/$NEW/sbin/start-cli.sh
echo -n "  本机正确密码 -> "; $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "show cluster" 2>&1 | head -1
EOS
