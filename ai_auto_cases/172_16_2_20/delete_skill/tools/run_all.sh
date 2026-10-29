#!/bin/bash
# run_all.sh — 先完整跑 IoTConsensus，再完整跑 IoTV2（无人值守，可续跑）
set -u
BASE=/data2/iotdb/rc10_matrix
LOG=$BASE/logs/run-all.log
mkdir -p "$BASE/logs"
echo "===== RUN-ALL START $(date -Is) =====" >> "$LOG"
bash "$BASE/scripts/run_matrix.sh" IoTConsensus >> "$LOG" 2>&1
echo "===== IoTConsensus DONE $(date -Is) =====" >> "$LOG"
bash "$BASE/scripts/run_matrix.sh" IoTV2 >> "$LOG" 2>&1
echo "===== RUN-ALL DONE $(date -Is) =====" >> "$LOG"
bash "$BASE/scripts/make_report.sh" >> "$LOG" 2>&1
