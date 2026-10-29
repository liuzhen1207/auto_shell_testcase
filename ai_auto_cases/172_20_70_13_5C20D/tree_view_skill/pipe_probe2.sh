#!/bin/bash
# 探针 v3：逐个试 inclusion 取值，看哪种能把"树转表视图"同步到接收端
set -u
DB=/data/iotdb/master_1026_dc11a35
S=172.20.70.100
R=172.20.70.110
run() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$1" \
  "cd $DB && ./sbin/start-cli.sh -h $1 -p 6667 -u root -pw TimechoDB@2021 -e \"set sql_dialect=$2; $3\"" 2>&1 | grep -v "^Warning"; }
t() { run "$1" tree "$2"; }
m() { run "$1" table "$2"; }
try() { # try <inclusion>
  inc="$1"
  m $S "drop pipe p_probe" >/dev/null 2>&1
  echo "----- inclusion='$inc'"
  m $S "create pipe p_t with source ('inclusion'='$inc') with sink ('node-urls'='$R:6667')"
  sleep 30
  echo "[接收端 表库]"; m $R "show databases" | grep -E "probe_view|Database" | head -3
  echo "[接收端 视图]"; m $R "desc probe_view.v" 2>&1 | head -4
  echo "[接收端 树库]"; t $R "show databases" | grep -E "pipe_probe|Database" | head -3
  m $S "drop pipe p_t" >/dev/null 2>&1
}
m $S "drop pipe p_probe" >/dev/null 2>&1
try "schema.table, data.insert"
try "all"
try "schema"
