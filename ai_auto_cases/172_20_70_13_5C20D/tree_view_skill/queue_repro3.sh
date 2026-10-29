#!/bin/bash
# 收尾复现（严格串行，绝不并发）：
#   1) TV-HA-03 干净复跑（验证 D5 为误报）
#   2) TV-REPRO-D1 v2（并发触发扩列）
#   3) TV-REPRO-D4 v2（写+查触发 DN 鉴权）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
LOG=logs/repro3.out
for c in TV-HA-03 TV-REPRO-D1 TV-REPRO-D4; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp4 "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c" >>"$LOG"
done
echo "### $(date '+%F %T') REPRO3 DONE" >>"$LOG"
