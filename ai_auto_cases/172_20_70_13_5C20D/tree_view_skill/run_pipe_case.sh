#!/bin/bash
# pipe 场景专用驱动：**两端都 prepare**（干净集群），再跑单条 pipe 用例。
# 用法：run_pipe_case.sh <sender-conf> <run-prefix> <case-id>
set -uo pipefail
SENDER_CONF="$1"; PREFIX="$2"; CASE="$3"
ROOT=/data1/iotdb/5c20dtest/testcase/PIPE
SKILL=/data1/iotdb/5c20dtest/testcase/TREEVIEW/treeview_5c20d
LOGDIR=$ROOT/logs
mkdir -p "$LOGDIR"
cd "$SKILL" || exit 1
RECV_CONF=conf/cluster.pipe_receiver.conf
RUN_ID="${PREFIX}_${CASE}"
LOG="$LOGDIR/${RUN_ID}.log"
echo "=== $(date '+%F %T') pipe case $CASE: prepare sender+receiver" >>"$LOG"

timeout 2700 bash scripts/pg.sh --conf "$SENDER_CONF" prepare >>"$LOG" 2>&1 || { echo "VERDICT $CASE PREPARE_SENDER_FAILED" | tee -a "$LOG"; exit 1; }
timeout 2700 bash scripts/pg.sh --conf "$RECV_CONF" prepare >>"$LOG" 2>&1 || { echo "VERDICT $CASE PREPARE_RECEIVER_FAILED" | tee -a "$LOG"; exit 1; }

timeout 5400 bash scripts/pg.sh --conf "$SENDER_CONF" run --run-id "$RUN_ID" --case "$CASE" >>"$LOG" 2>&1
rc=$?
RUN_DIR="$SKILL/results/$RUN_ID"
[ -d "$RUN_DIR" ] || RUN_DIR=$(ls -d /data1/iotdb/5c20dtest/testcase/PIPE/pipe_sender/results/$RUN_ID 2>/dev/null | head -1)
bash scripts/pg.sh --conf "$SENDER_CONF" report "$RUN_DIR" >>"$LOGDIR/${RUN_ID}.report.log" 2>&1
STATUS=$(python3 - "$RUN_DIR" "$CASE" <<'PY'
import json, sys, pathlib
f = pathlib.Path(sys.argv[1]) / "cases" / sys.argv[2] / "result.json"
print(json.loads(f.read_text(encoding="utf-8"))["status"] if f.is_file() else "NO_RESULT")
PY
)
echo "VERDICT $CASE $STATUS" | tee -a "$LOG"

if [ "$STATUS" != "PASS" ] && [ "$STATUS" != "SKIP" ]; then
  EV="$RUN_DIR/cases/$CASE/evidence"; mkdir -p "$EV/logs"
  for conf in "$SENDER_CONF" "$RECV_CONF"; do
    DB_DIR=$(grep -E '^DB_DIR=' "$conf" | head -1 | cut -d= -f2)
    NODES=$(grep -E '^NODES_FILE=' "$conf" | head -1 | cut -d= -f2)
    for h in $(awk '$1 ~ /dn/ {print $2}' "$NODES"); do
      role=dn
      awk '$1 ~ /cn/ {print $2}' "$NODES" | grep -qx "$h" && role=cn
      for pair in "cn:confignode" "dn:datanode"; do
        r=${pair%%:*}; pre=${pair##*:}
        [ "$r" = "cn" ] && ! awk '$1 ~ /cn/ {print $2}' "$NODES" | grep -qx "$h" && continue
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$h" \
          "cd $DB_DIR/logs 2>/dev/null && tar czf - log_${pre}_all.log log_${pre}_error.log log_${pre}_warn.log 2>/dev/null" \
          > "$EV/logs/${r}_${h}.tar.gz" 2>/dev/null
        [ -s "$EV/logs/${r}_${h}.tar.gz" ] || rm -f "$EV/logs/${r}_${h}.tar.gz"
      done
    done
  done
fi
exit $rc
