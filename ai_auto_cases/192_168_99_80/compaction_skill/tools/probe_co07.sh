#!/bin/bash
# 诊断 3：**device 路径** 才是 insert 的 prefixPath（之前把序列路径当成 device → 506 already exist）
CLI=/data/iotdb/testdb/v20121rc6_1010_7ae8713e/sbin/start-cli.sh
H=192.168.99.77
run(){ echo "### $1"; $CLI -h $H -u root -pw 'TimechoDB@2021' -timeout 3600 -e "$1" 2>&1 | head -3; echo "---"; }
run "create database root.probe09;"
for spec in "a int32 plain" "b int64 plain" "c float plain" "d double plain" "e text plain" "f boolean plain" "g timestamp plain"; do
  set -- $spec; d=$1; t=$2; e=$3
  run "create timeseries root.probe09.$d.s with datatype=$t encoding=$e;"
  case "$t" in
    int32*|int64*) v=42 ;;
    float*|double*) v=1.5 ;;
    text) v="'abc'" ;;
    boolean) v=true ;;
    timestamp) v=1700000000000 ;;
  esac
  run "insert into root.probe09.$d(time,s) values (1700000000000,$v);"
  run "select count(s) from root.probe09.$d.s;"
done
echo "### 特殊字面量（device 路径正确时）："
run "create timeseries root.probe09.h.s with datatype=double encoding=plain;"
run "insert into root.probe09.h(time,s) values (1700000000000,NaN);"
run "insert into root.probe09.h(time,s) values (1700000001000,'Infinity');"
run "insert into root.probe09.i.s with datatype=int64;" 2>/dev/null
run "create timeseries root.probe09.i.s with datatype=int32 encoding=plain;"
run "insert into root.probe09.i(time,s) values (1700000000000,2147483647);"
run "insert into root.probe09.i(time,s) values (1700000001000,-2147483648);"
run "create timeseries root.probe09.j.s with datatype=text encoding=plain;"
run "insert into root.probe09.j(time,s) values (1700000000000,'sp,ec@l中 文1');"
run "drop database root.probe09;"
