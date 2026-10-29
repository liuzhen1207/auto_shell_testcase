#!/bin/bash
# pipe 组复跑（修正 show pipes 方言 / 行数断言 / 双集群日志扫描后）
set -u
ROOT=/data1/iotdb/5c20dtest/testcase/PIPE
LOG=$ROOT/logs/queue_pipe2.out
mkdir -p "$ROOT/logs"
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
for c in TV-PIPE-04 TV-PIPE-05 TV-PIPE-06 TV-PIPE-07 TV-PIPE-08 TV-PIPE-09 TV-PIPE-03; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe2 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE_PIPE2 DONE" >>"$LOG"
