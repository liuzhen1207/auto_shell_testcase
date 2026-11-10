#!/bin/bash
set -u
C=/data2/iotdb/v20131rc2_1110_83183d0/sbin/start-cli.sh
H=172.16.2.13
R2=/data1/iotdb/v20131rc2_1110_83183d0
q(){ timeout 90 $C -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
mk(){ q "create timeseries $1.$2.s with datatype=INT32;" >/dev/null 2>&1; q "insert into $1.$2(time,s) values($3,1);" >/dev/null 2>&1; }
map(){ q "explain select s from $1.d0 where time=$2;" | grep -o 'Partition: [0-9]*' | head -1; }
wait_cn(){ for i in $(seq 1 30); do n=$(q 'show datanodes;' | grep -c '|Running|'); [ "${n:-0}" -ge 5 ] && return 0; sleep 5; done; }

echo "=== A) INHERIT（默认）"
q 'drop database root.i132;' >/dev/null 2>&1
q 'create database root.i132;' >/dev/null
for i in 0 1 2; do mk root.i132 d$i $i; done
q 'insert into root.i132.d0(time,s) values(700000000,9);' >/dev/null
q 'insert into root.i132.d0(time,s) values(1400000000,9);' >/dev/null
echo "t0=$(map root.i132 0) t1=$(map root.i132 700000000) t2=$(map root.i132 1400000000)（INHERIT 预期同一组）"

echo "=== B) SHUFFLE"
for h in 8 9 10; do
  ssh -n -o BatchMode=yes root@172.16.2.$h "F=$R2/conf/iotdb-system.properties; grep -q '^data_partition_allocation_strategy=' \$F && sed -i 's|^data_partition_allocation_strategy=.*|data_partition_allocation_strategy=SHUFFLE|' \$F || echo 'data_partition_allocation_strategy=SHUFFLE' >> \$F; pkill -9 -f confignode" 2>/dev/null
done
sleep 5
for h in 8 9 10; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R2 && ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 55
q 'drop database root.s132;' >/dev/null 2>&1
q 'create database root.s132;' >/dev/null
for i in 0 1 2; do mk root.s132 d$i $i; done
q 'insert into root.s132.d0(time,s) values(700000000,9);' >/dev/null
q 'insert into root.s132.d0(time,s) values(1400000000,9);' >/dev/null
echo "t0=$(map root.s132 0) t1=$(map root.s132 700000000) t2=$(map root.s132 1400000000)（SHUFFLE 预期分散到不同组）"

echo "=== 恢复 INHERIT"
for h in 8 9 10; do
  ssh -n -o BatchMode=yes root@172.16.2.$h "F=$R2/conf/iotdb-system.properties; sed -i '/^data_partition_allocation_strategy=/d' \$F; pkill -9 -f confignode" 2>/dev/null
done
sleep 5
for h in 8 9 10; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R2 && ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 50
echo "restored, running_dn=$(q 'show datanodes;' | grep -c '|Running|')"
