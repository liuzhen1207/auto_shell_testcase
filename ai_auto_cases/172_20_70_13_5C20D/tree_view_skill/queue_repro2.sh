#!/bin/bash
# D1(v2) 并发触发 + D4(v2) 数据查询触发
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/repro2.out
for c in TV-REPRO-D1 TV-REPRO-D4; do
  echo "### $(date '+%F %T') START $c (v2)" >>"$LOG"
  bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp3 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE REPRO2 DONE" >>"$LOG"
