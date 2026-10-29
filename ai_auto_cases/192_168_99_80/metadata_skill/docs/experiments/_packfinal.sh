#!/bin/bash
cd /data/iotdb/autotest/metadata_skill/results || exit 1
tar czf /tmp/md_final13.tgz MD-*_run.out
echo "=== CSV 关键列 ==="
awk -F, 'NR>1{printf "%-28s %-5s %-5s %s\n", $4, $5, $6, $9}' test_result.csv
echo "=== 套件输出 ==="
ls SUITE_all_20261010_163319.out
echo "=== 用例日志 ==="
ls MD-*_run.out | wc -l
