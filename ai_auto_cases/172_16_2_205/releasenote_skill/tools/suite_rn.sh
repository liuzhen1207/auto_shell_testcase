#!/bin/bash
# ============================================================================
# releasenote_skill 套件执行器
#   usage: suite_rn.sh [case-id ...]      不带参数跑全部
#   产物：results/run_<时间戳>/results.tsv 与 <ID>.out
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf" "$BASE/scripts/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
for _p in "$BASE/lib/lib_rn.sh" "$BASE/scripts/lib_rn.sh"; do [ -f "$_p" ] && . "$_p" && break; done
if ! command -v T >/dev/null 2>&1; then echo "环境错误：未加载 lib_rn.sh"; exit 4; fi

RESULTS="$RESULT_ROOT/run_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS"
RES="$RESULTS/results.tsv"
printf 'id\tfeature\ttype\tverdict\tfails\tdur_s\tdetail\n' > "$RES"

# 已知失败清单：每行 "CASE_ID|原因"，命中则不计为 FAIL（记为 KNOWN）
declare -a KNOWN_IDS=() KNOWN_REASONS=()
KF="$BASE/conf/known_failures.conf"
if [ -f "$KF" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    KNOWN_IDS+=("${line%%|*}")
    KNOWN_REASONS+=("${line#*|}")
  done < "$KF"
fi

declare -a CASES=()
for f in "$BASE"/cases/*.sh; do
  [ -f "$f" ] || continue
  . "$f"
done

want=("$@")
[ ${#want[@]} -eq 0 ] && want=()

echo "[$(date +%T)] ReleaseNote suite start, results=$RESULTS, cases=${#CASES[@]}"

for entry in "${CASES[@]}"; do
  IFS='|' read -r id feature ctype desc fn <<< "$entry"
  if [ ${#want[@]} -gt 0 ]; then
    hit=0; for w in ${want[@]+"${want[@]}"}; do [ "$w" = "$id" ] && hit=1; done
    [ "$hit" = "0" ] && continue
  fi
  echo "[$(date +%T)] ===== $id | $feature | $ctype | $desc"
  CASE_FAILS=0; CASE_MSGS=""
  t0=$(date +%s)
  "$fn" >> "$RESULTS/$id.out" 2>&1
  t1=$(date +%s)
  dur=$((t1 - t0))
  verdict=PASS
  if [ "$CASE_FAILS" -gt 0 ]; then
    verdict=FAIL
    for i in ${KNOWN_IDS[@]+"${KNOWN_IDS[@]}"}; do
      if [ "$i" = "$id" ]; then
        verdict=KNOWN
        CASE_MSGS="${CASE_MSGS}[known] $(for j in ${!KNOWN_IDS[@]+"${!KNOWN_IDS[@]}"}; do [ "${KNOWN_IDS[$j]}" = "$id" ] && echo "${KNOWN_REASONS[$j]}"; done)"
        break
      fi
    done
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$ctype" "$verdict" "$CASE_FAILS" "$dur" "$CASE_MSGS" >> "$RES"
  echo "[$(date +%T)] $id -> $verdict (fails=$CASE_FAILS ${dur}s)"
done

echo "[$(date +%T)] ReleaseNote suite done"
awk -F'\t' 'NR>1{c[$4]++} END{for(k in c) print k, c[k]}' "$RES"
[ "$(awk -F'\t' 'NR>1 && $4!="PASS" && $4!="KNOWN"' "$RES" | wc -l)" -gt 0 ] && exit 10
exit 0
