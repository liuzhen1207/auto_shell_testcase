#!/bin/bash
# 树转表 5C20D 自动化回归总入口
#   1) 两套集群先停干净
#   2) 单集群用例（TV-BASE/SYNC/HA/LEAK/REF/REPRO，**不含 TV-PIPE**）逐条跑，每条独立 prepare
#   3) 再停干净
#   4) 最后跑 pipe 组（双集群，组内每条两端 prepare，组前后各停一次）
set -uo pipefail
ROOT=/data1/iotdb/5c20dtest/testcase/PIPE
SKILL=/data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d
LOGDIR=$ROOT/logs
mkdir -p "$LOGDIR"
LOG=$LOGDIR/regress_all.out
cd "$SKILL" || exit 1

stop_both() {
  echo "=== $(date '+%F %T') stop both clusters ($1)" >>"$LOG"
  timeout 900 bash scripts/pg.sh --conf conf/cluster.pipe_sender.conf   teardown >>"$LOG" 2>&1
  timeout 900 bash scripts/pg.sh --conf conf/cluster.pipe_receiver.conf teardown >>"$LOG" 2>&1
}

echo "=== $(date '+%F %T') REGRESSION START" >>"$LOG"
stop_both "before regression"

# 单集群用例清单（不含 pipe）由注册表生成，避免手工漏项
CASES=$(PYTHONPATH=scripts python3 - <<'PY'
from pgkit import cases
for c in cases.CASES:
    if not c.case_id.startswith("TV-PIPE-"):
        print(c.case_id)
PY
)
echo "=== $(date '+%F %T') 单集群用例：$(echo "$CASES" | wc -l) 条" >>"$LOG"
for c in $CASES; do
  echo "### $(date '+%F %T') START $c" >>"$LOG"
  bash /data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d/run_case_clean.sh \
      conf/cluster.treeview_5c20d.conf tv "$c" >>"$LOG" 2>&1
  echo "### $(date '+%F %T') END $c rc=$?" >>"$LOG"
done

stop_both "before pipe group"
bash treeview_5c20d/run_pipe_group.sh >>"$LOG" 2>&1
stop_both "after regression"
echo "=== $(date '+%F %T') REGRESSION DONE" >>"$LOG"
