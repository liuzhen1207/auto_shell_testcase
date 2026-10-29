#!/bin/bash
# Re-classify a finished run: assertions vs feature-path log errors vs HA/restart noise.
# usage: classify_run.sh <run-dir>
set -u
R="${1:-/data2/auto_test/treeview_suite/results/run_20261027_180439}"
OUT=$R/classified.tsv
HA='RouteBalancer|CHANGE_REGION_LEADER|read-only|ShutdownHook|UPDATE_REGION_ROUTE_MAP|UPDATE_TABLE|INVALIDATE_LAST_CACHE|CREATE_SCHEMA_REGION|RaftServerImpl|GrpcLogAppender|requestVote|appendEntries|DataNodeAuthUtils|Cannot pull system configurations|Fail to start server|shutdown failed|leader may have been down|Timeout during|borrow ConfigNodeClient|Failed to sync logEntries|Template .* does not exist|PIPE_HEARTBEAT|PIPE_PUSH_ALL_META|PIPE_PUSH_META|Failed to FLUSH|PipeHeartbeatRPCHandler'

printf 'id\tfeature\ttype\tverdict\tassert_fails\tfeat_err\tha_err\tother_err\tdur_s\tdetail\n' > "$OUT"
tail -n +2 "$R/results.tsv" | while IFS=$'\t' read -r id feature ctype verdict fails errs dur detail; do
  d="$R/${id}_logdelta"
  tot=0; feat=0; ha=0; other=0
  if [ -d "$d" ]; then
    tot=$(grep -h ' ERROR ' "$d"/new_*.txt 2>/dev/null | wc -l)
    feat=$(grep -h ' ERROR ' "$d"/new_*.txt 2>/dev/null | grep -c 'ViewColumnAutoSyncTrigger')
    ha=$(grep -h ' ERROR ' "$d"/new_*.txt 2>/dev/null | grep -v 'ViewColumnAutoSyncTrigger' | grep -cE "$HA")
    other=$((tot - feat - ha))
    [ "$other" -lt 0 ] && other=0
  fi
  v=PASS
  [ "${fails:-0}" -gt 0 ] && v=FAIL_ASSERT
  if [ "$v" = "PASS" ] && [ "$feat" -gt 0 ]; then v=FAIL_FEATURE_LOG; fi
  if [ "$v" = "PASS" ] && [ "$other" -gt 0 ]; then v=FAIL_OTHER_LOG; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$ctype" "$v" "${fails:-0}" "$feat" "$ha" "$other" "$dur" "$detail" >> "$OUT"
done
echo "=== verdicts ==="
awk -F'\t' 'NR>1{c[$4]++} END{for(k in c) print k, c[k]}' "$OUT"
echo "=== feature-path ERROR cases ==="
awk -F'\t' 'NR>1 && $6>0 {print $1, $6}' "$OUT"
echo "=== other-ERROR cases ==="
awk -F'\t' 'NR>1 && $8>0 {print $1, $8}' "$OUT"
echo "classified -> $OUT"
