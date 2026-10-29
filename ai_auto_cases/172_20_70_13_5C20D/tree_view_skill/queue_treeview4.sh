#!/bin/bash
# 收尾队列：最后 3 条需复跑的用例
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview4.out
CONF=conf/cluster.treeview_5c20d.conf
RUNNER=treeview_5c20d/run_case_clean.sh
for c in TV-BASE-08 TV-REF-06 TV-HA-03; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash "$RUNNER" "$CONF" tv4 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c rc=$?" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE4 DONE" >>"$LOG"
