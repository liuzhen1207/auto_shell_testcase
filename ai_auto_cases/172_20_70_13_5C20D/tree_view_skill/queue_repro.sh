#!/bin/bash
# 疑似产品缺陷的最小复现队列（每条独立干净集群；FAIL 自动备份 CN/DN 日志）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/repro.out
for c in TV-REPRO-D4 TV-REPRO-D2 TV-REPRO-D3 TV-REPRO-D1 TV-REPRO-D5; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c" >>"$LOG"
done
echo "### $(date '+%F %T') REPRO DONE" >>"$LOG"
