#!/bin/bash
# D4 定点复跑（跨 20 台 DN 查询）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/repro5.out
echo "### $(date '+%F %T') START TV-REPRO-D4 v3" >>"$LOG"
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp6 TV-REPRO-D4 >>"$LOG" 2>&1
echo "### $(date '+%F %T') DONE" >>"$LOG"
