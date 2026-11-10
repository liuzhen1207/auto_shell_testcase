#!/bin/bash
set -u
C=/data2/iotdb/v20131rc1_1030_ab6d3de/sbin/start-cli.sh
H=172.16.2.13
R1=/data1/iotdb/v20131rc1_1030_ab6d3de
LOG=/tmp/pgc124_126_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
q(){ timeout 90 $C -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
cnt(){ q "show $2 regions of database $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5==db && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }
mk(){ q "create timeseries $1.$2.s with datatype=INT32;" >/dev/null 2>&1; q "insert into $1.$2(time,s) values($3,1);" >/dev/null 2>&1; }
wait_run(){ for i in $(seq 1 40); do n=$(q 'show datanodes;' | grep -c '|Running|'); [ "${n:-0}" -ge "$1" ] && return 0; sleep 5; done; return 1; }

echo "=== PGC-124 可用 DN 不足（停 3 个 DN，剩 2 < DR=3）"
for h in 11 12 13; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R1 && ./sbin/stop-datanode.sh" >/dev/null 2>&1 || true; done
sleep 45
echo "running=$(q 'show datanodes;' | grep -c '|Running|')"
q 'drop database root.r124;' >/dev/null 2>&1
echo "create db:"; q 'create database root.r124;' | tail -2
echo "create timeseries:"; q 'create timeseries root.r124.d0.s with datatype=INT32;' | tail -2
echo "insert:"; q 'insert into root.r124.d0(time,s) values(0,1);' | tail -2
echo "groups after failure attempt: schema=$(cnt root.r124 schema) data=$(cnt root.r124 data)"
for h in 11 12 13; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R1 && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null; done
wait_run 5 || echo "WARN not all DN back"
echo "DN back: running=$(q 'show datanodes;' | grep -c '|Running|')"
q 'drop database root.r124;' >/dev/null 2>&1

echo "=== PGC-125 建组中停 DN（部分成功/重试）"
q 'drop database root.r125;' >/dev/null 2>&1
q 'create database root.r125;' >/dev/null
( for i in 0 1 2 3 4 5; do mk root.r125 d$i $i; echo "$i" >> /tmp/r125_ins.log; sleep 2; done ) &
BG=$!
sleep 5
echo "stop DN15 at $(date +%T)"
ssh -n -o BatchMode=yes root@172.16.2.15 "cd $R1 && ./sbin/stop-datanode.sh" >/dev/null 2>&1 || true
wait $BG
sleep 15
echo "r125 groups: schema=$(cnt root.r125 schema) data=$(cnt root.r125 data), inserts=$(wc -l < /tmp/r125_ins.log 2>/dev/null)"
echo "r125 region ids:"
q 'show data regions of database root.r125;' | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5=="root.r125" && $2 ~ /^[0-9]+$/) print $2}' | sort -u | tr '\n' ','; echo
q 'select count(*) from root.r125.d0;' | tail -4
ssh -n -o BatchMode=yes root@172.16.2.15 "cd $R1 && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null
wait_run 5 || echo "WARN DN15"
echo "after DN15 back groups=$(cnt root.r125 data) running=$(q 'show datanodes;' | grep -c '|Running|')"

echo "=== PGC-126 remove DN 后 cap 下降、加回后 cap 上升"
q 'drop database root.r125;' >/dev/null 2>&1
sleep 3
id=$(q 'show datanodes;' | awk -F'|' '{gsub(/ /,"",$4);if($4=="172.16.2.15"){gsub(/ /,"",$2);print $2}}' | head -1)
echo "remove datanode $id"; q "remove datanode $id;" | tail -2
for i in $(seq 1 40); do q 'show datanodes;' | grep -q '172.16.2.15' || break; sleep 5; done
q 'create database root.r126;' >/dev/null
for i in 0 1 2 3 4 5 6 7 8; do mk root.r126 d$i $i; done
echo "r126 (4 DN): data=$(cnt root.r126 data) expect 6"
ssh -n -o BatchMode=yes root@172.16.2.15 "cd $R1 && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null
wait_run 5 || echo "WARN readd"
q 'insert into root.r126.d0(time,s) values(700000000,9);' >/dev/null
echo "r126 after readd: data=$(cnt root.r126 data) expect 7"
echo "[$(date +%T)] done"
