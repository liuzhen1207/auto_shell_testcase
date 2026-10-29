#!/bin/bash
# 冲突场景三条路径实测：创建(无FIELD) / 创建(指定类型) / 开关切换
set -u
DB=/data/iotdb/master_1026_dc11a35
S=172.20.70.100
run() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$1" \
  "cd $DB && ./sbin/start-cli.sh -h $1 -p 6667 -u root -pw TimechoDB@2021 -e \"set sql_dialect=$2; $3\"" 2>&1 | grep -v "^Warning"; }
t() { run "$1" tree "$2"; }
m() { run "$1" table "$2"; }

echo "===== 准备：同名测点 s1 在两个设备上类型不同"
t $S "create database root.pc" >/dev/null
t $S "create timeseries root.pc.d1.s1 INT32" >/dev/null
t $S "create timeseries root.pc.d2.s1 DOUBLE" >/dev/null
m $S "create database pc1" >/dev/null
m $S "create database pc2" >/dev/null
m $S "create database pc3" >/dev/null
m $S "create database pc4" >/dev/null

echo "----- A) CREATE VIEW 不声明 FIELD（必须扫描）"
m $S "create view pc1.v (dev string tag) as root.pc.**" | head -3

echo "----- B) CREATE VIEW 声明 s1 DOUBLE FIELD（不需要扫描）"
m $S "create view pc2.v (dev string tag, s1 double field) as root.pc.**" | head -3
m $S "desc pc2.v" | head -8

echo "----- C) CREATE VIEW 声明 s1 FIELD（不给类型，需扫描定类型）"
m $S "create view pc3.v (dev string tag, s1 field) as root.pc.**" | head -3

echo "----- D) 已有视图（s1 DOUBLE），把 auto_sync_schema 从 false 改 true"
m $S "alter view pc2.v set properties auto_sync_schema=true" | head -2
m $S "show create view pc2.v" | grep -o "auto_sync_schema=[a-z]*"
m $S "desc pc2.v" | head -8

echo "----- E) 开自动同步后再新增一个类型冲突的测点（s1 已是 DOUBLE，再来 INT64）"
t $S "create timeseries root.pc.d3.s1 INT64" | head -2
sleep 15
m $S "desc pc2.v" | head -8
echo "-- DN 日志里是否有 305/552:"
ssh -o BatchMode=yes root@$S "grep -a 'ViewColumnAutoSyncTrigger' $DB/logs/log_datanode_all.log | tail -2 | cut -c1-200" 2>/dev/null
