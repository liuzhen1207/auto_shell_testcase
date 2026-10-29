#!/bin/bash
# rerun_failures.sh — 重跑所有"最后一次判定不是 PASS"的轮次（矩阵只跳过 PASS）
set -u
BASE=/data2/iotdb/rc10_matrix
LOG=$BASE/logs/rerun.log
echo "===== RERUN START $(date -Is) =====" >> "$LOG"
for P in IoTConsensus IoTV2; do
  awk -F'\t' -v p="$P" '$1==p{last[$2]=$6} END{for(c in last) if(last[c]!="PASS") print c}' "$BASE/results/results.tsv" | sort > "/tmp/rerun_$P.txt"
  while read -r c; do
    [ -z "${c:-}" ] && continue
    [ -s "$BASE/cases/$c/run.sql" ] || { echo "[$(date +%H:%M:%S)] no-spec $P/$c" >> "$LOG"; continue; }
    echo "[$(date +%H:%M:%S)] RERUN $P/$c" >> "$LOG"
    bash "$BASE/scripts/run_round.sh" "$P" "$c" >> "$LOG" 2>&1
    echo "[$(date +%H:%M:%S)] RERUN-END $P/$c -> $(tail -n 1 "$BASE/results/results.tsv" | cut -f6)" >> "$LOG"
  done < "/tmp/rerun_$P.txt"
done
echo "===== RERUN DONE $(date -Is) =====" >> "$LOG"
bash "$BASE/scripts/make_report.sh" >> "$LOG" 2>&1
