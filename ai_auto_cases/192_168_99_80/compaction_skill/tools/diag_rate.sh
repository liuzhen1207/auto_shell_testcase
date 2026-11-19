#!/bin/bash
# 诊断：1KB TEXT（UNCOMPRESSED）批量写入为什么没落盘
set -uo pipefail
cd /data/iotdb/autotest/compaction_skill || exit 1
. lib/common.sh; . lib/cmp.sh
cmp_load_env
P=$(printf 'x%.0s' $(seq 1 1000))
echo "payload len=${#P}"
echo "--- create db ---"
sq "create database root.ratetest;" 2>&1 | tail -1
echo "--- create ts (UNCOMPRESSED) ---"
sq "create timeseries root.ratetest.d1.s1 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tail -1
echo "--- insert 2 rows ---"
sq "insert into root.ratetest.d1(time,s1) values (1,'$P'),(2,'$P');" 2>&1 | tail -2
sq "flush;" >/dev/null
sleep 8
for h in "${DN[@]}"; do echo -n "  $h files: "; sshx "$h" "find $DB_DIR/data/datanode/data -path '*ratetest*' -name '*.tsfile' | wc -l"; done
echo "--- insert 200 rows ---"
vals=""; for k in $(seq 1 200); do vals="$vals($(( 100+k )),'$P'),"; done
sq "insert into root.ratetest.d1(time,s1) values ${vals%,};" 2>&1 | tail -2
sq "flush;" >/dev/null
sleep 8
for h in "${DN[@]}"; do echo -n "  $h files: "; sshx "$h" "find $DB_DIR/data/datanode/data -path '*ratetest*' -name '*.tsfile' | wc -l"; done
echo "--- 行数 ---"
sq "select count(s1) from root.ratetest.**;" 2>&1 | tail -3
