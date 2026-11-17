#!/bin/bash
# TDB-1104 变体：3C4D 启动 → 造 CUSTOM 10 组空 region → 扩容第 5 台 DN → 空 region 迁移/缩容到新 DN
set -u
NEW=/data1/iotdb/v20131rc2_1110_83183d0
CLI=/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh
PW='TimechoDB@2021'
Q(){ bash $CLI -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
T(){ bash $CLI -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
DNS="19 21 22 23 24"
mark(){ M="TDB1104X-$1-$(date +%s)"; echo "$M" > /tmp/mark_$1; for n in $DNS; do ssh -n -o BatchMode=yes root@172.16.2.$n "echo $M >> $NEW/logs/log_datanode_all.log" 2>/dev/null; done; echo "$M"; }
check(){ M=$(cat /tmp/mark_$1 2>/dev/null); local total=0
  for n in $DNS; do
    c=$(ssh -n -o BatchMode=yes root@172.16.2.$n "awk -v m='$M' 'index(\$0,m){f=1} f' $NEW/logs/log_datanode_all.log 2>/dev/null | grep -icE 'NullPointerException|snapshot.*(fail|error|exception)|addPeer.*(fail|error)'" 2>/dev/null)
    echo "  dn$n=${c:-0}"; total=$((total+${c:-0}))
  done
  echo "  合计=$total"; }

echo "=== 1) 启动 3C4D ==="
NEW=$NEW CLI=$CLI bash /data2/iotdb/rc10_matrix/scripts/start_3c4d.sh 2>&1 | tail -n 8

echo "=== 2) CUSTOM 策略 + 10 组空 region ==="
T 'SET CONFIGURATION "data_region_group_extension_policy"="CUSTOM";' >/dev/null
T 'SET CONFIGURATION "default_data_region_group_num_per_database"="10";' >/dev/null
Q "CREATE DATABASE tdb1104x WITH (max_data_region_group_num=10);" | tail -n 1
Q "CREATE TABLE tdb1104x.t (dev STRING TAG, v INT32 FIELD);" >/dev/null
Q "INSERT INTO tdb1104x.t(time,dev,v) VALUES (1796690000000,'d1',1);" >/dev/null
Q "FLUSH;" >/dev/null
sleep 6
echo "--- 4D 时 region（组数 / 空组） ---"
Q "SHOW REGIONS;" | grep -i tdb1104x | grep DataRegion | awk -F'|' '{print $2}' | sort -u | tr '\n' ' '; echo
Q "SHOW REGIONS;" | grep -i tdb1104x | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u | tr '\n' ' '; echo

echo "=== 3) 扩容第 5 台 DN（24） ==="
mark expand >/dev/null
ssh -n -o BatchMode=yes root@172.16.2.24 "rm -f $NEW/logs/log_datanode_all.log; setsid bash $NEW/sbin/start-datanode.sh -d >/tmp/dn24_start.log 2>&1 </dev/null" 2>/dev/null
for t in $(seq 1 60); do n=$(bash $CLI -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null | grep -c '|Running|'); [ "${n:-0}" -ge 8 ] && break; sleep 5; done
echo "cluster=$n"
echo "--- 扩容后 region ---"
Q "SHOW REGIONS;" | grep -i tdb1104x | grep DataRegion | awk -F'|' '{print $2, $6, $8}' | sort -u
echo "--- DN24 的 nodeId ---"
Q "SHOW DATANODES;" | grep 172.16.2.24

echo "=== 4) 空 region 迁移到新 DN ==="
DNID=$(Q "SHOW DATANODES;" | grep 172.16.2.24 | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -n1)
echo "DN24 id=$DNID"
M=$(mark migrate); echo "mark=$M"
for rid in $(Q "SHOW REGIONS;" | grep -i tdb1104x | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u | head -n 5); do
  echo "--- region $rid -> extend 到 $DNID ---"
  Q "EXTEND REGION $rid TO $DNID;" | grep -oE 'successfully|Exception[^\n]{0,70}' | tail -n1
  sleep 10
  Q "REMOVE REGION $rid FROM $DNID;" | grep -oE 'successfully|Exception[^\n]{0,70}' | tail -n1
  sleep 10
done
check migrate

echo "=== 5) LOAD BALANCE TO DATANODE $DNID ==="
M=$(mark balance); echo "mark=$M"
Q "LOAD BALANCE TO DATANODE $DNID;" | tail -n 2
sleep 40
check balance
Q "SHOW REGIONS;" | grep -i tdb1104x | grep DataRegion | awk -F'|' '{print $2, $6, $8}' | sort -u
