#!/bin/bash
# 诊断：对比几种 count SQL 的输出
CLI=/data/iotdb/testdb/v20121rc6_1010_7ae8713e/sbin/start-cli.sh
H=192.168.99.77
DB=${1:-root.cometa}
for sql in "select count(s1) from $DB.**;" "select count(s1) from $DB.d1.s1;" "select count(s1) from $DB.d1.**;" "select s1 from $DB.d1 order by time;"; do
  echo "### $sql"
  printf '%s\n' "$sql" | $CLI -h $H -u root -pw 'TimechoDB@2021' 2>&1 | grep -vE '^ *[|+_-]+$' | sed -n '9,20p'
  echo "---"
done
