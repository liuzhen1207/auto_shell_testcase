#!/bin/bash
# pipe 用例串行队列：等待前面的 pipe 运行结束 → 逐条跑（每条都会 prepare 两端）
set -u
ROOT=/data1/iotdb/5c20dtest/testcase/PIPE
LOG=$ROOT/logs/queue_pipe.out
mkdir -p "$ROOT/logs"
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
# 等当前正在跑的 pipe 用例结束
while pgrep -f "run_pipe_case.sh conf/cluster.pipe_sender.conf" > /dev/null; do sleep 60; done
for c in TV-PIPE-02 TV-PIPE-04 TV-PIPE-05 TV-PIPE-06 TV-PIPE-07 TV-PIPE-08 TV-PIPE-09; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c" >>"$LOG"
done
echo "### $(date '+%F %T') QUEUE_PIPE DONE" >>"$LOG"
