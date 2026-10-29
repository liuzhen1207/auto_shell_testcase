#!/bin/bash
# Suite runner for the tree-view auto-sync-schema cases.
# usage: suite.sh [case-id-substring ...]
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -f "$BASE/conf/env.conf" ] && . "$BASE/conf/env.conf"
NEW=${NEW:-master_1026_dc11a35}
CLI=${CLI:-/data2/iotdb/$NEW/sbin/start-cli.sh}
PW=${PW:-TimechoDB@2021}
RESULTS=$BASE/results/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$RESULTS"
. $BASE/lib/lib.sh

declare -a CASES=()
for f in $BASE/cases/*.sh; do . "$f"; done

echo "[$(date '+%T')] suite start, results=$RESULTS, cases=${#CASES[@]}"
RES=$RESULTS/results.tsv
printf 'id\tfeature\ttype\tverdict\tfails\terrs\tdur_s\tdetail\n' > "$RES"

FILTER="$*"
for entry in "${CASES[@]}"; do
  IFS='|' read -r id feature ctype desc fn verify_sql clean_before <<< "$entry"
  if [ -n "$FILTER" ]; then
    match=0
    for f in $FILTER; do case "$id" in *$f*) match=1;; esac; done
    [ "$match" = "1" ] || continue
  fi
  echo "[$(date '+%T')] ===== $id | $feature | $ctype | $desc"
  CASE_FAILS=0; CASE_MSGS=""
  t0=$(date +%s)
  if [ "${clean_before:-0}" = "1" ]; then
    echo "  clean cluster before case"
    bash $BASE/reset_cluster.sh > "$RESULTS/${id}_reset.log" 2>&1 || echo "  reset failed (see log)"
    sleep 20
  fi
  log_mark_all
  out="$RESULTS/${id}.out"
  : > "$out"
  "$fn" >> "$out" 2>&1
  # log delta check (case-induced)
  errs=0
  log_scan_delta "$RESULTS/${id}_logdelta" >/dev/null 2>&1
  errs=$(grep -h ' ERROR ' "$RESULTS/${id}_logdelta"/new_*.txt 2>/dev/null | wc -l)
  # sync lag + replica consistency
  lag_ok=1
  wait_sync_lag_zero 180 >> "$out" 2>&1 || lag_ok=0
  cons_ok=1
  if [ -n "${verify_sql:-}" ]; then
    replica_consistency "172.16.2.2,172.16.2.5" "$verify_sql" >> "$out" 2>&1 || cons_ok=0
  fi
  t1=$(date +%s); dur=$((t1 - t0))
  verdict=PASS
  [ "$CASE_FAILS" -gt 0 ] && verdict=FAIL
  [ "$errs" -gt 0 ] && verdict=FAIL
  [ "$lag_ok" = "0" ] && verdict=FAIL
  [ "$cons_ok" = "0" ] && verdict=FAIL
  detail=$(echo "$CASE_MSGS" | cut -c1-400)
  [ "$errs" -gt 0 ] && detail="$detail logERROR=$errs"
  [ "$lag_ok" = "0" ] && detail="$detail syncLagNotZero"
  [ "$cons_ok" = "0" ] && detail="$detail replicaMismatch"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$ctype" "$verdict" "$CASE_FAILS" "$errs" "$dur" "$detail" >> "$RES"
  echo "[$(date '+%T')] $id -> $verdict (fails=$CASE_FAILS logErr=$errs lag=$lag_ok cons=$cons_ok ${dur}s)"
  if [ "$verdict" = "FAIL" ]; then
    backup_logs "$id"
  fi
done
echo "[$(date '+%T')] suite done"
awk -F'\t' 'NR>1{c[$4]++} END{for(k in c) print k, c[k]}' "$RES"
