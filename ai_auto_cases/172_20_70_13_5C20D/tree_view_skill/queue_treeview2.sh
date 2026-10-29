#!/bin/bash
# 补充用例（参考用例回归 6 条 + OBJECT 加列 1 条）：主队列跑完后执行
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview2.out
CONF=conf/cluster.treeview_5c20d.conf
RUNNER=treeview_5c20d/run_case_clean.sh
for c in TV-REF-01 TV-REF-02 TV-REF-03 TV-REF-04 TV-REF-05 TV-REF-06 TV-SYNC-16; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash "$RUNNER" "$CONF" tv2 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c rc=$?" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE2 DONE" >>"$LOG"
