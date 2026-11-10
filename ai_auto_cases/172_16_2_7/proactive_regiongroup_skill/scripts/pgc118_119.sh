#!/bin/bash
set -u
CLI=/data2/iotdb/v20131rc1_1030_ab6d3de/sbin/start-cli.sh
H=172.16.2.13
LOG=/tmp/pgc118_119_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
q(){ timeout 90 $CLI -h $H -p 6667 -u root -pw 'TimechoDB@2021' -sql_dialect tree -e "$1" 2>&1; }
cnt(){ q "show $2 regions of database $1;" | awk -F'|' -v db="$1" '{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5==db && $2 ~ /^[0-9]+$/) print $2}' | sort -u | wc -l; }
mk(){ q "create timeseries $1.$2.s with datatype=INT32;" >/dev/null 2>&1; q "insert into $1.$2(time,s) values($3,1);" >/dev/null 2>&1; }

echo "=== PGC-118 逐 slot 增长"
q 'drop database root.g118;' >/dev/null 2>&1
q 'create database root.g118;' >/dev/null
echo "slots | schema | data | data_slot_sum"
for i in 0 1 2 3 4 5; do
  mk root.g118 d$i $i
  s=$(cnt root.g118 schema); d=$(cnt root.g118 data)
  sum=$(q 'show data regions of database root.g118;' | awk -F'|' '{gsub(/ /,"",$5);gsub(/ /,"",$6);if($5=="root.g118" && $6 ~ /^[0-9]+$/) print $6}' | sort -u | paste -sd+ | bc 2>/dev/null)
  echo "$((i+1)) | $s | $d | ${sum:-n/a}"
done
echo "data region detail:"
q 'show data regions of database root.g118;' | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$6);if($5=="root.g118" && $2 ~ /^[0-9]+$/) print "RegionId="$2" slots="$6}'

echo "=== PGC-119 新组承接后续时间分区"
q 'drop database root.m119;' >/dev/null 2>&1
q "SET CONFIGURATION 'data_region_group_extension_policy'='AUTO';" >/dev/null
q "SET CONFIGURATION 'schema_region_group_extension_policy'='AUTO';" >/dev/null
q 'create database root.m119;' >/dev/null
for i in 0 1 2; do mk root.m119 d$i $i; done
echo "AUTO 3 slots: schema=$(cnt root.m119 schema) data=$(cnt root.m119 data)"
echo "before groups:"
q 'show data regions of database root.m119;' | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$6);if($5=="root.m119" && $2 ~ /^[0-9]+$/) print $2"/"$6}' | sort -u
q "SET CONFIGURATION 'data_region_group_extension_policy'='PROACTIVE';" >/dev/null
q "SET CONFIGURATION 'schema_region_group_extension_policy'='PROACTIVE';" >/dev/null
for i in 3 4 5; do mk root.m119 d$i $i; done
echo "after PROACTIVE 6 slots: data=$(cnt root.m119 data)"
echo "after groups:"
q 'show data regions of database root.m119;' | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$6);if($5=="root.m119" && $2 ~ /^[0-9]+$/) print $2"/"$6}' | sort -u
echo "write new time partition for d0 (t=700000000)"
q 'insert into root.m119.d0(time,s) values(700000000,9);' >/dev/null
echo "after new time partition:"
q 'show data regions of database root.m119;' | awk -F'|' '{gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$6);if($5=="root.m119" && $2 ~ /^[0-9]+$/) print $2"/"$6}' | sort -u
