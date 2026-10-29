#!/bin/bash
# Pipe（数据同步）用例组：**开始前、结束后都把两端集群停干净**，避免与其它场景互相干扰。
# 组内每条用例由 run_pipe_case.sh 负责"两端 prepare（干净集群）+ 执行 + 收尾三件套"。
set -uo pipefail
ROOT=/data1/iotdb/5c20dtest/testcase/PIPE
SKILL=/data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d
LOGDIR=$ROOT/logs
mkdir -p "$LOGDIR"
LOG=$LOGDIR/pipe_group.out
cd "$SKILL" || exit 1

stop_both() {
  echo "=== $(date '+%F %T') stop both clusters ($1)" >>"$LOG"
  timeout 900 bash scripts/pg.sh --conf conf/cluster.pipe_sender.conf   teardown >>"$LOG" 2>&1
  timeout 900 bash scripts/pg.sh --conf conf/cluster.pipe_receiver.conf teardown >>"$LOG" 2>&1
  echo "=== $(date '+%F %T') both clusters stopped" >>"$LOG"
}

stop_both "before pipe group"
FAILED=0
for c in TV-PIPE-01 TV-PIPE-02 TV-PIPE-03 TV-PIPE-04 TV-PIPE-05 TV-PIPE-06 TV-PIPE-07 TV-PIPE-08 TV-PIPE-09; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe "$c" >>"$LOG" 2>&1
  rc=$?
  echo "### $(date '+%F %T') END $c rc=$rc" >>"$LOG"
  [ $rc -ne 0 ] && FAILED=$((FAILED+1))
done
stop_both "after pipe group"
echo "### $(date '+%F %T') PIPE GROUP DONE failed=$FAILED" >>"$LOG"
exit 0
