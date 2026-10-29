#!/bin/bash
# 5C20D 树转表视图（tree view）：**每条用例都从干净集群开始**的串行驱动。
#   每个用例：stop → 清 data/logs → 写 conf → 启动 → 跑该用例（含收尾三件套）→ 出报告
#   判定 FAIL 时额外把 CN/DN 日志打包进该用例的 evidence 目录。
# 用法：run_case_clean.sh <conf> <run-prefix> <case-id>
set -uo pipefail
CONF="$1"
PREFIX="$2"
CASE="$3"

ROOT=/data1/iotdb/5c20dtest/testcase/TREEVIEW
SKILL=$ROOT/treeview_5c20d
LOGDIR=$ROOT/logs
mkdir -p "$LOGDIR"
cd "$SKILL" || exit 1

# pipe 用例必须两端 prepare，走 run_pipe_case.sh；这里直接拒绝，避免"只 prepare 了发送端"造成假失败
case "$CASE" in
  TV-PIPE-*)
    echo "ERROR: $CASE 是双集群 pipe 用例，请用 run_pipe_case.sh（会 prepare 发送端+接收端）：" >&2
    echo "  bash treeview_5c20d/run_pipe_case.sh conf/cluster.pipe_sender.conf pipe $CASE" >&2
    exit 2;;
esac

PREPARE_TIMEOUT=${PREPARE_TIMEOUT:-2700}
CASE_TIMEOUT=${CASE_TIMEOUT:-5400}
DB_DIR=$(grep -E '^DB_DIR=' "$CONF" | head -1 | cut -d= -f2)
NODES=$SKILL/conf/nodes.conf
CN_HOSTS=$(awk '$1 ~ /cn/ {print $2}' "$NODES" | tr '\n' ' ')
DN_HOSTS=$(awk '$1 ~ /dn/ {print $2}' "$NODES" | tr '\n' ' ')

RUN_ID="${PREFIX}_${CASE}"
BATCH_LOG="$LOGDIR/${RUN_ID}.log"
echo "=== $(date '+%F %T') clean start for $CASE (conf=$CONF)" >>"$BATCH_LOG"

rm -rf /tmp/rcdn-ssh-* 2>/dev/null || true

timeout "$PREPARE_TIMEOUT" bash scripts/pg.sh --conf "$CONF" prepare >>"$BATCH_LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "=== $(date '+%F %T') prepare FAILED rc=$rc for $CASE" >>"$BATCH_LOG"
  echo "VERDICT $CASE PREPARE_FAILED 0s" >>"$BATCH_LOG"
  exit $rc
fi

timeout "$CASE_TIMEOUT" bash scripts/pg.sh --conf "$CONF" run --run-id "$RUN_ID" --case "$CASE" \
    >>"$BATCH_LOG" 2>&1
rc=$?
echo "=== $(date '+%F %T') case $CASE run rc=$rc" >>"$BATCH_LOG"

RUN_DIR="$SKILL/results/$RUN_ID"
[ -d "$RUN_DIR" ] || RUN_DIR="$ROOT/results/$RUN_ID"
bash scripts/pg.sh --conf "$CONF" report "$RUN_DIR" >>"$LOGDIR/${RUN_ID}.report.log" 2>&1

STATUS=$(python3 - "$RUN_DIR" "$CASE" <<'PY'
import json, sys, pathlib
run, case = pathlib.Path(sys.argv[1]), sys.argv[2]
f = run / "cases" / case / "result.json"
print(json.loads(f.read_text(encoding="utf-8"))["status"] if f.is_file() else "NO_RESULT")
PY
)
echo "VERDICT $CASE $STATUS" | tee -a "$BATCH_LOG"

# ---- FAIL / NO_RESULT 时备份 CN/DN 日志（用户要求） -------------------------
if [ "$STATUS" != "PASS" ] && [ "$STATUS" != "SKIP" ]; then
  EV="$RUN_DIR/cases/$CASE/evidence"
  mkdir -p "$EV/logs"
  echo "=== $(date '+%F %T') 备份 CN/DN 日志（verdict=$STATUS）" >>"$BATCH_LOG"
  for h in $(printf '%s\n%s\n' "$CN_HOSTS" "$DN_HOSTS" | tr ' ' '\n' | sort -u); do
    # 同机双角色（.100~.104）要**两份**都备：CN 与 DN 的日志是不同文件
    for pair in "cn:confignode" "dn:datanode"; do
      role=${pair%%:*}; prefix=${pair##*:}
      case " $CN_HOSTS " in *" $h "*) ;; *) [ "$role" = "cn" ] && continue;; esac
      case " $DN_HOSTS " in *" $h "*) ;; *) [ "$role" = "dn" ] && continue;; esac
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$h" \
        "cd $DB_DIR/logs 2>/dev/null && tar czf - log_${prefix}_all.log log_${prefix}_error.log log_${prefix}_warn.log 2>/dev/null" \
        > "$EV/logs/${role}_${h}.tar.gz" 2>/dev/null
      [ -s "$EV/logs/${role}_${h}.tar.gz" ] || rm -f "$EV/logs/${role}_${h}.tar.gz"
    done
  done
  ls -la "$EV/logs" >>"$BATCH_LOG" 2>&1
fi

exit $rc
