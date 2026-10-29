#!/bin/bash
# 树转表视图 34 条用例的串行队列：每条都从干净集群开始；FAIL 自动备份 CN/DN 日志。
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/queue_treeview.out
CONF=conf/cluster.treeview_5c20d.conf
RUNNER=treeview_5c20d/run_case_clean.sh
run() {
  echo "### $(date '+%F %T') START $1" >>"$LOG"
  bash "$RUNNER" "$CONF" tv "$1" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $1 rc=$?" >>"$LOG"
}
# 先跑冒烟/基础，再跑自动扩列，最后 HA 与泄漏
for c in TV-BASE-01 TV-BASE-02 TV-BASE-03 TV-BASE-06 TV-BASE-09 TV-BASE-13 TV-BASE-14 \
         TV-SYNC-01 TV-SYNC-04 TV-SYNC-05 TV-SYNC-06 TV-SYNC-08 TV-SYNC-10 TV-SYNC-12 \
         TV-SYNC-02 TV-SYNC-07 TV-SYNC-09 TV-SYNC-11 TV-SYNC-13 TV-SYNC-14 TV-SYNC-15 \
         TV-BASE-04 TV-BASE-05 TV-BASE-07 TV-BASE-08 TV-BASE-10 TV-BASE-11 TV-BASE-12 TV-BASE-15 \
         TV-HA-01 TV-HA-02 TV-HA-03 TV-LEAK-01; do
  run "$c"
done
echo "### $(date '+%F %T') QUEUE DONE" >>"$LOG"
