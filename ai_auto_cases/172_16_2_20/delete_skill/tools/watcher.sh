#!/bin/bash
# watcher.sh — 等主跑批结束后，自动重跑所有非 PASS 轮次并重出报告
BASE=/data2/iotdb/rc10_matrix
LOG=$BASE/logs/watcher.log
echo "[$(date -Is)] watcher started, waiting for run_all.sh" >> $LOG
while pgrep -f 'scripts/run_all.sh' >/dev/null 2>&1; do sleep 300; done
echo "[$(date -Is)] run_all finished; starting rerun" >> $LOG
bash $BASE/scripts/rerun_failures.sh >> $LOG 2>&1
echo "[$(date -Is)] watcher done" >> $LOG