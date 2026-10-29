#!/bin/bash
# run_matrix.sh <IoTConsensus|IoTV2> — resumable sequential matrix over all case rounds
set -u
PROTO=$1
BASE=/data2/iotdb/rc10_matrix
LOG=$BASE/logs/matrix-$PROTO.log
DONE=$BASE/results/results.tsv
MAN=$BASE/manifest-$PROTO.tsv
mkdir -p $BASE/logs
touch $DONE
echo "===== MATRIX START $PROTO $(date -Is) =====" >> $LOG
consec_fail=0
while IFS=$'\t' read -r case stage; do
  [ -z "${case:-}" ] && continue
  if awk -F'\t' -v p="$PROTO" -v c="$case" '$1==p && $2==c && $6=="PASS"{f=1} END{exit f?0:1}' "$DONE"; then
    echo "[$(date +%H:%M:%S)] skip(already PASS) $case" >> $LOG
    continue
  fi
  if [ ! -s "$BASE/cases/$case/run.sql" ]; then
    echo "[$(date +%H:%M:%S)] skip(NO SPEC) $case" >> $LOG
    printf '%s\t%s\t-\t-\t0\tSKIP_NO_SPEC\t-\n' "$PROTO" "$case" >> "$DONE"
    continue
  fi
  echo "[$(date +%H:%M:%S)] RUN $case ($stage)" >> $LOG
  bash "$BASE/scripts/run_round.sh" "$PROTO" "$case" >> "$LOG" 2>&1
  last=$(tail -n 1 "$DONE" | cut -f1,2,6)
  echo "[$(date +%H:%M:%S)] RESULT $case -> $last" >> $LOG
  case "$last" in
    *FAIL_RESET*|*FAIL_CLUSTER*) consec_fail=$((consec_fail+1)) ;;
    *) consec_fail=0 ;;
  esac
  if [ "$consec_fail" -ge 3 ]; then
    echo "[$(date +%H:%M:%S)] ABORT: 3 consecutive cluster failures" >> $LOG
    exit 3
  fi
done < "$MAN"
echo "===== MATRIX END $PROTO $(date -Is) =====" >> $LOG