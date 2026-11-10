#!/bin/bash
set -u
R12=/data1/iotdb/v20121rc12_1027_c05111d
R2=/data1/iotdb/v20131rc2_1110_83183d0
LIC='03-AAATKKLP-XREBT2T7-2QRCC==='
CLI2=/data2/iotdb/v20131rc2_1110_83183d0/sbin/start-cli.sh
C12=$R12/sbin/start-cli.sh
LOG=/tmp/upg_rc12_rc2_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date +%T)] stop all"
for h in 8 9 10 11 12 13 14 15; do ssh -n -o BatchMode=yes root@172.16.2.$h "pkill -9 java" 2>/dev/null; done
sleep 6
echo "[$(date +%T)] prepare RC12 clean"
for h in 8 9 10 11 12 13 14 15; do
  ip=172.16.2.$h
  ssh -n -o BatchMode=yes root@$ip "rm -rf $R12/data $R12/logs; mkdir -p $R12/data $R12/logs
    F=$R12/conf/iotdb-system.properties
    for kv in 'cluster_name=ClusterID_upg' 'cn_internal_address=$ip' 'cn_seed_config_node=172.16.2.8:10710' 'dn_seed_config_node=172.16.2.8:10710' 'dn_internal_address=$ip' 'dn_rpc_address=$ip' 'schema_replication_factor=3' 'data_replication_factor=3' 'schema_region_group_extension_policy=AUTO' 'data_region_group_extension_policy=AUTO'; do
      k=\${kv%%=*}; v=\${kv#*=}
      grep -q \"^\$k=\" \$F && sed -i \"s|^\$k=.*|\$k=\$v|\" \$F || echo \"\$k=\$v\" >> \$F
    done
    mkdir -p $R12/activation; echo '$LIC' > $R12/activation/license" 2>/dev/null
done
for h in 8 9 10; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R12 && ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 50
for h in 11 12 13 14 15; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R12 && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 70
for i in $(seq 1 12); do n=$(timeout 60 $C12 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -e 'show datanodes;' 2>/dev/null | grep -c '|Running|'); [ "${n:-0}" -ge 5 ] && break; sleep 10; done
echo "RC12 running_dn=${n:-0}"
echo "[$(date +%T)] RC12 baseline"
timeout 90 $C12 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -e 'create database root.upg;' >/dev/null 2>&1
for i in 0 1 2 3 4 5; do
  timeout 60 $C12 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -e "create timeseries root.upg.d$i.s with datatype=INT32;" >/dev/null 2>&1
  timeout 60 $C12 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -e "insert into root.upg.d$i(time,s) values($i,1);" >/dev/null 2>&1
done
show(){ timeout 60 $C12 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -e 'show data regions of database root.upg;' 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5=="root.upg" && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }
echo "RC12 AUTO 6 slots data=$(show)（预期 2）"
echo "[$(date +%T)] stop RC12, copy data to RC2"
for h in 8 9 10 11 12 13 14 15; do ssh -n -o BatchMode=yes root@172.16.2.$h "pkill -9 java" 2>/dev/null; done
sleep 6
for h in 8 9 10 11 12 13 14 15; do
  ip=172.16.2.$h
  ssh -n -o BatchMode=yes root@$ip "rm -rf $R2/data_bak_upg; mv $R2/data $R2/data_bak_upg 2>/dev/null || true; cp -a $R12/data $R2/data; rm -rf $R2/logs; mkdir -p $R2/logs
    F=$R2/conf/iotdb-system.properties
    for kv in 'cluster_name=ClusterID_upg' 'cn_seed_config_node=172.16.2.8:10710' 'dn_seed_config_node=172.16.2.8:10710' 'schema_region_group_extension_policy=AUTO' 'data_region_group_extension_policy=AUTO'; do
      k=\${kv%%=*}; v=\${kv#*=}
      grep -q \"^\$k=\" \$F && sed -i \"s|^\$k=.*|\$k=\$v|\" \$F || echo \"\$k=\$v\" >> \$F
    done" 2>/dev/null
done
echo "[$(date +%T)] start RC2"
for h in 8 9 10; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R2 && ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 55
for h in 11 12 13 14 15; do ssh -n -o BatchMode=yes root@172.16.2.$h "cd $R2 && ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" 2>/dev/null; sleep 2; done
sleep 75
for i in $(seq 1 12); do n=$(timeout 60 $CLI2 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e 'show datanodes;' 2>/dev/null | grep -c '|Running|'); [ "${n:-0}" -ge 5 ] && break; sleep 10; done
echo "RC2 running_dn=${n:-0}"
echo "--- cluster"; timeout 60 $CLI2 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e 'show cluster;' 2>&1 | tail -10
echo "--- config"; timeout 60 $CLI2 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e 'show configuration;' 2>&1 | grep -i 'data_region_group_extension_policy' | head -1
echo "--- groups after upgrade"; timeout 60 $CLI2 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e 'show data regions of database root.upg;' 2>&1 | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5=="root.upg" && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l
echo "--- data check"; timeout 60 $CLI2 -h 172.16.2.13 -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e 'select count(*) from root.upg.d0;' 2>&1 | tail -4
echo "[$(date +%T)] done"
