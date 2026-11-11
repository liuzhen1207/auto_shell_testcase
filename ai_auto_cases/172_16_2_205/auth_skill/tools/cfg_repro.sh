#!/bin/bash
# 受控复现：SET CONFIGURATION 对 iotdb-system.properties 的累积效应 + 重启后仍生效
NEW=v20131rc2_1110_83183d0
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
T() { timeout 30 $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
CFG=/data1/iotdb/$NEW/conf/iotdb-system.properties

show_cfg() {  # $1 = DN ip, $2 = tag
  echo "--- $2: DN $1 文件状态 ---"
  ssh -n -o StrictHostKeyChecking=no root@$1 "wc -l < $CFG; grep -n 'enforce_strong_password' $CFG; grep -n '^#.*2026' $CFG | tail -3" 2>/dev/null
}

echo "=========== 1) 变更前 ==========="
show_cfg 172.16.2.2 before
echo -n "  当前策略值（show configuration）: "
T "show configuration" 2>/dev/null | grep enforce_strong_password | head -1

echo
echo "=========== 2) SET CONFIGURATION 'enforce_strong_password'='false' ==========="
T "SET CONFIGURATION 'enforce_strong_password'='false'" | head -1
sleep 3
show_cfg 172.16.2.2 after_false
echo "--- 文件末尾 12 行 ---"
ssh -n -o StrictHostKeyChecking=no root@172.16.2.2 "tail -12 $CFG" 2>/dev/null

echo
echo "=========== 3) 行为验证：弱口令应被接受 ==========="
T "drop user cfgchk" >/dev/null 2>&1
echo -n "  create user 'weakpassword': "
T "create user cfgchk 'weakpassword'" | head -1
T "drop user cfgchk" >/dev/null 2>&1

echo
echo "=========== 4) 重启 DN6（kill -9 + 启动），验证持久化 ==========="
PID=$(ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null)
ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "kill -9 $PID" 2>/dev/null
sleep 5
ssh -n -o StrictHostKeyChecking=no root@172.16.2.6 "source /etc/profile; cd /data1/iotdb/$NEW; nohup /data1/iotdb/$NEW/sbin/start-datanode.sh -H /data1/iotdb/$NEW/dn.hprof > /data1/iotdb/$NEW/start_dn.log 2>&1 &" 2>/dev/null
for i in $(seq 1 40); do n=$(T "show cluster;" 2>/dev/null | grep -c Running); [ "$n" -ge 8 ] && break; sleep 6; done
echo "  重启后 Running=$n"
sleep 10
echo -n "  重启后再试弱口令: "
T "drop user cfgchk" >/dev/null 2>&1
T "create user cfgchk 'weakpassword'" | head -1
T "drop user cfgchk" >/dev/null 2>&1
show_cfg 172.16.2.6 after_restart

echo
echo "=========== 5) 恢复 true ==========="
T "SET CONFIGURATION 'enforce_strong_password'='true'" | head -1
sleep 3
echo -n "  恢复后弱口令应被拒: "
T "drop user cfgchk" >/dev/null 2>&1
T "create user cfgchk 'weakpassword'" | head -1
T "drop user cfgchk" >/dev/null 2>&1
show_cfg 172.16.2.2 restored
