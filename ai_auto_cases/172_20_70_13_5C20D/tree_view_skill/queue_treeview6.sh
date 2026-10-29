#!/bin/bash
# TV-HA-03 复现率确认：连跑 2 次
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview6.out
for i in 1 2; do
  echo "### $(date '+%F %T') START TV-HA-03 run$i" >>"$LOG"
  bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf ha$i TV-HA-03 >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END run$i rc=$?" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE6 DONE" >>"$LOG"
