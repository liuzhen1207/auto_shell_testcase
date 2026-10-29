#!/bin/bash
cd /data/iotdb/autotest/metadata_skill/results || exit 1
tar czf /tmp/md_last13.tgz MD-*_run.out
echo "=== CSV ==="
awk -F, 'NR>1{printf "%-26s %-5s %-4s %s\n", $4, $5, $6, $9}' test_result.csv
ls SUITE_all_20261010_201222.out; ls MD-*_run.out | wc -l
