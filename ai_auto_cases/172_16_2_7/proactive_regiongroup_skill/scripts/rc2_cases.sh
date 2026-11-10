#!/bin/bash
set -u
C=/data2/iotdb/v20131rc2_1110_83183d0/sbin/start-cli.sh
H=172.16.2.13
R1=/data1/iotdb/v20131rc2_1110_83183d0
LOG=/tmp/rc2_cases_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
q(){ timeout 90 $C -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect "$1" -e "$2" 2>&1; }
tbl(){ q table "$1"; }
tree(){ q tree "$1"; }
cnt(){ tree "show $2 regions of database $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5==db && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }
cnt_tbl(){ tbl "show $2 regions from $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5==db && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }
sum_slots(){ tree "show data regions of database $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$6);if($5==db && $2 ~ /^[0-9]+$/) print $2" "$6}' | sort -u | awk '{s+=$2} END{print s+0}'; }
pol(){ tree "SET CONFIGURATION '$1'='$2';" >/dev/null 2>&1; }
devs(){ local db=$1 n=$2; for i in $(seq 0 $((n-1))); do tree "create timeseries $db.d$i.s with datatype=INT32;" >/dev/null 2>&1; tree "insert into $db.d$i(time,s) values($i,1);" >/dev/null 2>&1; done; }
cleanup(){ for db in root.g131 root.a133 root.p133; do tree "drop database $db;" >/dev/null 2>&1; done; tbl 'drop database t128;' >/dev/null 2>&1; tbl 'drop database t128b;' >/dev/null 2>&1; }
wait_run(){ for i in $(seq 1 30); do n=$(tree 'show datanodes;' | grep -c '|Running|'); [ "${n:-0}" -ge 5 ] && return 0; sleep 5; done; }

cleanup; sleep 3
echo "=== PGC-128 表模型 CUSTOM ALTER + PROACTIVE"
pol data_region_group_extension_policy CUSTOM; pol schema_region_group_extension_policy CUSTOM
tbl 'create database t128 with MAX_DATA_REGION_GROUP_NUM=4, MAX_SCHEMA_REGION_GROUP_NUM=2;' | tail -1
tbl 'use t128; create table base(device string tag, v int64 field);' >/dev/null
tbl "use t128; insert into base(device,time,v) values('d0',1,1),('d1',1,1),('d2',1,1),('d3',1,1),('d4',1,1),('d5',1,1),('d6',1,1),('d7',1,1),('d8',1,1);" >/dev/null
echo "t128 9 devices CUSTOM(4/2): schema=$(cnt_tbl t128 schema) data=$(cnt_tbl t128 data) expect 2/4"
tbl 'alter database t128 with MAX_DATA_REGION_GROUP_NUM=6, MAX_SCHEMA_REGION_GROUP_NUM=3;' | tail -1
echo "after alter (no new partition): schema=$(cnt_tbl t128 schema) data=$(cnt_tbl t128 data)"
tbl "use t128; insert into base(device,time,v) values('d9',1,1);" >/dev/null
echo "after new device: schema=$(cnt_tbl t128 schema) data=$(cnt_tbl t128 data) expect 3/6"
pol data_region_group_extension_policy PROACTIVE; pol schema_region_group_extension_policy PROACTIVE
tbl 'drop database t128;' >/dev/null 2>&1
tbl 'create database t128b;' | tail -1
tbl 'use t128b; create table base(device string tag, v int64 field);' >/dev/null
tbl "use t128b; insert into base(device,time,v) values('d0',1,1),('d1',1,1),('d2',1,1),('d3',1,1),('d4',1,1),('d5',1,1),('d6',1,1),('d7',1,1),('d8',1,1);" >/dev/null
echo "t128b 9 devices PROACTIVE: schema=$(cnt_tbl t128b schema) data=$(cnt_tbl t128b data) expect 2/7"
tbl 'drop database t128b;' >/dev/null 2>&1

echo "=== PGC-131 删除后 slot/组不回收"
tree 'create database root.g131;' >/dev/null
devs root.g131 9
echo "before: groups=$(cnt root.g131 data) slots=$(sum_slots root.g131)"
for i in 0 1 2; do tree "delete timeseries root.g131.d$i.s;" >/dev/null 2>&1; done
echo "after delete 3 series: groups=$(cnt root.g131 data) slots=$(sum_slots root.g131)"
tree 'delete from root.g131.d3 where time>=0;' >/dev/null 2>&1
echo "after delete rows: groups=$(cnt root.g131 data) slots=$(sum_slots root.g131)"
tree 'drop database root.g131;' >/dev/null 2>&1

echo "=== PGC-133 热更新后重启 CN 配置保持"
pol data_region_group_extension_policy AUTO; pol schema_region_group_extension_policy AUTO
tree 'create database root.a133;' >/dev/null
devs root.a133 9
echo "AUTO 9 slot: schema=$(cnt root.a133 schema) data=$(cnt root.a133 data) expect 1/2"
pol data_region_group_extension_policy PROACTIVE; pol schema_region_group_extension_policy PROACTIVE
tree 'drop database root.a133;' >/dev/null 2>&1
sleep 3
echo "restart CN9"
ssh -n -o BatchMode=yes root@172.16.2.9 "pkill -9 -f confignode; sleep 3; cd $R1 && ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" 2>/dev/null
sleep 45
echo "config on node1 after restart:"; tbl 'show configuration on 1;' | grep -i 'data_region_group_extension_policy' | head -1
tree 'create database root.p133;' >/dev/null
devs root.p133 9
echo "after restart PROACTIVE 9 slot: schema=$(cnt root.p133 schema) data=$(cnt root.p133 data) expect 2/7"
echo "[$(date +%T)] done"
