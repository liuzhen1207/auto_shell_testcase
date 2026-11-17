#!/bin/bash
# TDB-1104 空 DataRegion 在 Adding/缩容时 load snapshot 空指针 —— 复现/验证脚本
# 环境：3C5D，RC2 83183d0，DN 19/21/22/23/24，CN 16/17/18
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
DNS=${DNS:-"19 21 22 23 24"}
q(){ bash "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ bash "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
mark(){ M="TDB1104-$1-$(date +%s)"; echo "$M" > /tmp/tdb1104_mark_$1; for n in $DNS; do ssh -n -o BatchMode=yes root@172.16.2.$n "echo $M >> $NEW/logs/log_datanode_all.log" 2>/dev/null; done; echo "$M"; }
check(){ M=$(cat /tmp/tdb1104_mark_$1 2>/dev/null); local total=0
  for n in $DNS; do
    c=$(ssh -n -o BatchMode=yes root@172.16.2.$n "awk -v m='$M' 'index(\$0,m){f=1} f' $NEW/logs/log_datanode_all.log 2>/dev/null | grep -icE 'NullPointerException|snapshot.*(fail|error|exception)|addPeer.*(fail|error)'" 2>/dev/null)
    echo "  dn$n=${c:-0}"; total=$((total+${c:-0}))
  done
  echo "  合计异常=$total"; }

echo "=== 1) CUSTOM 策略造空 region（TREE 方言热改） ==="
t 'SET CONFIGURATION "data_region_group_extension_policy"="CUSTOM";' | tail -n 1
t 'SET CONFIGURATION "default_data_region_group_num_per_database"="10";' | tail -n 1
q "CREATE DATABASE tdb1104i WITH (max_data_region_group_num=10);" | tail -n 1
q "CREATE TABLE tdb1104i.t (dev STRING TAG, v INT32 FIELD);" >/dev/null
q "INSERT INTO tdb1104i.t(time,dev,v) VALUES (1796670000000,'d1',1);" >/dev/null
q "FLUSH;" >/dev/null
t "CREATE DATABASE root.tdb1104tree;" | tail -n 1
t "CREATE TIMESERIES root.tdb1104tree.d1.s1 WITH DATATYPE=INT32, ENCODING=PLAIN;" >/dev/null
t "INSERT INTO root.tdb1104tree.d1(timestamp,s1) VALUES (1796680000000,1);" >/dev/null
t "FLUSH;" >/dev/null
sleep 6
echo "--- 表模型空 region ---"; q "SHOW REGIONS;" | grep -i tdb1104i | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u | tr '\n' ' '; echo
echo "--- tree 模型空 region ---"; t "SHOW REGIONS;" | grep -i tdb1104tree | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u | tr '\n' ' '; echo

echo "=== 2) 表模型：空 region 扩缩容 ==="
M=$(mark table); echo "mark=$M"
for rid in $(q "SHOW REGIONS;" | grep -i tdb1104i | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u); do
  q "EXTEND REGION $rid TO 3;" >/dev/null 2>&1; sleep 10
  q "REMOVE REGION $rid FROM 3;" >/dev/null 2>&1; sleep 10
  echo "  region $rid done"
done
check table

echo "=== 3) tree 模型：空 region 扩缩容 ==="
M=$(mark tree); echo "mark=$M"
for rid in $(t "SHOW REGIONS;" | grep -i tdb1104tree | grep DataRegion | awk -F'|' '$6+0==0{print $2}' | sort -u); do
  t "EXTEND REGION $rid TO 4;" >/dev/null 2>&1; sleep 10
  t "REMOVE REGION $rid FROM 4;" >/dev/null 2>&1; sleep 10
  echo "  region $rid done"
done
check tree

echo "=== 4) 清理 ==="
t 'SET CONFIGURATION "data_region_group_extension_policy"="PROACTIVE";' >/dev/null
t 'SET CONFIGURATION "default_data_region_group_num_per_database"="2";' >/dev/null
for db in tdb1104i tdb1104e tdb1104f tdb1104 tdb1104b tdb1104c tdb1104g tdb1104h; do q "DROP DATABASE $db;" >/dev/null 2>&1; done
t "DROP DATABASE root.tdb1104tree;" >/dev/null 2>&1
echo "done"