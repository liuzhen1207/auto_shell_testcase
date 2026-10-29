#!/bin/bash
# D1 定点复跑（批量激活 + 连续扩模板）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/repro4.out
echo "### $(date '+%F %T') START TV-REPRO-D1 v3" >>"$LOG"
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp5 TV-REPRO-D1 >>"$LOG" 2>&1
echo "### $(date '+%F %T') DONE" >>"$LOG"
