#!/bin/bash
# 最终复跑：TV-BASE-08（断言修正后）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview5.out
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf tv5 TV-BASE-08 >>"$LOG" 2>&1
echo "### $(date '+%F %T') QUEUE5 DONE" >>"$LOG"
