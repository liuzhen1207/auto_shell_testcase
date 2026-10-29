#!/bin/bash
# 单独复跑 D4（触发条件修正后）
set -u
cd /data1/iotdb/5c20dtest/testcase/TREEVIEW || exit 1
echo "### $(date '+%F %T') START TV-REPRO-D4 (v2)" >>logs/repro_d4.out
bash treeview_5c20d/run_case_clean.sh conf/cluster.treeview_5c20d.conf rp2 TV-REPRO-D4 >>logs/repro_d4.out 2>&1
echo "### $(date '+%F %T') DONE" >>logs/repro_d4.out
