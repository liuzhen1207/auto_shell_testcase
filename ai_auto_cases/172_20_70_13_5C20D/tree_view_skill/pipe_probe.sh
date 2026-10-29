#!/bin/bash
# pipe 行为探针 v2：区分 sql_dialect（tree/table）
set -u
DB=/data/iotdb/master_1026_dc11a35
S=172.20.70.100
R=172.20.70.110
run() { # run <host> <dialect> <sql>
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$1" \
    "cd $DB && ./sbin/start-cli.sh -h $1 -p 6667 -u root -pw TimechoDB@2021 -e \"set sql_dialect=$2; $3\"" 2>&1 | grep -v "^Warning"
}
t() { run "$1" tree "$2"; }
m() { run "$1" table "$2"; }
echo "===== [1] 发送端准备"
t $S "create database root.pipe_probe"
t $S "create timeseries root.pipe_probe.d1.s1 INT32"
t $S "create timeseries root.pipe_probe.d1.s2 DOUBLE"
t $S "insert into root.pipe_probe.d1(time,s1,s2) values(1,10,1.5)"
m $S "create database probe_view"
m $S "create view probe_view.v (dev string tag, s1 int32 field, s2 double field) as root.pipe_probe.**"
m $S "select dev, s1, s2 from probe_view.v"
echo "===== [2] 建 pipe（schema.table + 数据）"
m $S "create pipe p_probe with source ('inclusion'='schema.table, data.insert') with sink ('node-urls'='$R:6667')"
m $S "show pipes"
echo "===== [3] 接收端核对（等 25s）"
sleep 25
m $R "show databases"
m $R "desc probe_view.v"
m $R "select dev, s1, s2 from probe_view.v"
echo "===== [4] 发送端 auto_sync 扩列 → 接收端是否同步"
m $S "alter view probe_view.v set properties auto_sync_schema=true"
t $S "create timeseries root.pipe_probe.d2.s3 INT64"
sleep 30
echo "-- 发送端 desc:"; m $S "desc probe_view.v"
echo "-- 接收端 desc:"; m $R "desc probe_view.v"
