#!/bin/bash
set -u
C=/data2/iotdb/v20131rc2_1110_83183d0/sbin/start-cli.sh
H=172.16.2.13
LOG=/tmp/rc2_cases2_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
t(){ timeout 90 $C -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect table -e "$1" 2>&1; }
r(){ timeout 90 $C -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
ct(){ t "show $2 regions from $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5==db && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }

echo "=== PGC-128 表模型 PROACTIVE 单库复测"
for db in t128 t128b t128c t128d; do t "drop database $db;" >/dev/null 2>&1; done
sleep 8
t 'show configuration;' | grep -i 'data_region_group_extension_policy' | head -1
t 'create database t128d;' | tail -1
t 'use t128d; create table base(device string tag, v int64 field);' >/dev/null
t "use t128d; insert into base(device,time,v) values('d0',1,1),('d1',1,1),('d2',1,1),('d3',1,1),('d4',1,1),('d5',1,1),('d6',1,1),('d7',1,1),('d8',1,1);" >/dev/null
echo "t128d 9 devices: schema=$(ct t128d schema) data=$(ct t128d data) expect 2/7"

echo "=== PGC-129 权限：普通用户改配置"
r "create user pgc_user 'TimechoDB@2026!';" | tail -1
r "grant read on root.** to user pgc_user;" | tail -1
timeout 60 $C -h $H -p 6667 -u pgc_user -pw 'TimechoDB@2026!' -sql_dialect tree -e "SET CONFIGURATION 'data_region_group_extension_policy'='PROACTIVE';" 2>&1 | tail -2
echo "=== 管理员对照"
r "SET CONFIGURATION 'data_region_group_extension_policy'='PROACTIVE';" | tail -2
t 'show configuration;' | grep -i 'data_region_group_extension_policy' | head -1
