#!/bin/bash
# 探针 v4：视图 DDL（schema）+ 底层树数据（data.insert,schema.timeseries）两条 pipe
set -u
DB=/data/iotdb/master_1026_dc11a35
S=172.20.70.100
R=172.20.70.110
run() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$1" \
  "cd $DB && ./sbin/start-cli.sh -h $1 -p 6667 -u root -pw TimechoDB@2021 -e \"set sql_dialect=$2; $3\"" 2>&1 | grep -v "^Warning"; }
t() { run "$1" tree "$2"; }
m() { run "$1" table "$2"; }
m $S "drop pipe p_t" >/dev/null 2>&1
echo "===== 建两条 pipe：schema（视图元数据）+ 树数据"
m $S "create pipe p_schema with source ('inclusion'='schema') with sink ('node-urls'='$R:6667')"
t $S "create pipe p_data with source ('inclusion'='data.insert, schema.timeseries') with sink ('node-urls'='$R:6667')"
t $S "show pipes" | grep -E "p_schema|p_data|State" | head -4
sleep 35
echo "===== 接收端：视图列 + 数据"
m $R "desc probe_view.v"
m $R "select dev, s1, s2 from probe_view.v"
t $R "select s1, s2 from root.pipe_probe.d1"
echo "===== 发送端：开 auto_sync 并新增测点 d3.s4"
m $S "alter view probe_view.v set properties auto_sync_schema=true"
t $S "create timeseries root.pipe_probe.d3.s4 FLOAT"
t $S "insert into root.pipe_probe.d3(time,s4) values(2, 3.5)"
sleep 35
echo "-- 发送端 desc:"; m $S "desc probe_view.v"
echo "-- 接收端 desc:"; m $R "desc probe_view.v"
echo "-- 接收端 数据:"; m $R "select dev, s1, s2 from probe_view.v"
