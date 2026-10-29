#!/bin/bash
# 第三队列：行解析修正（去掉表头）后需要复跑的用例
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview3.out
CONF=conf/cluster.treeview_5c20d.conf
RUNNER=treeview_5c20d/run_case_clean.sh
for c in TV-REF-06 TV-REF-01 TV-HA-03 TV-BASE-12 TV-BASE-07 TV-BASE-08 TV-SYNC-11 TV-BASE-06 TV-BASE-14 TV-SYNC-01 TV-BASE-04 TV-SYNC-15 TV-BASE-01 TV-BASE-11 TV-BASE-13 TV-SYNC-05 TV-SYNC-09 TV-REF-03 TV-REF-05; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash "$RUNNER" "$CONF" tv3 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c rc=$?" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE3 DONE" >>"$LOG"
