#!/bin/bash
# 身份鉴别用例执行器：逐例执行 + 8 节点日志增量检查 + 结果表
# usage: suite_auth.sh [case-id ...]   （不带参数跑全部）
set -u
BASE=${BASE:-$(cd "$(dirname "$0")/.." && pwd)}
for _p in "$BASE/conf/env.conf" "$BASE/scripts/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
NEW=${NEW:-v20121rc12_1027_c05111d}
export NEW

RESULTS=$BASE/results/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$RESULTS"
RES=$RESULTS/results.tsv
printf 'id\tfeature\ttype\tverdict\tfails\terrs\tdur_s\tdetail\n' > "$RES"

for _p in "$BASE/lib/lib_auth.sh" "$BASE/scripts/lib_auth.sh"; do [ -f "$_p" ] && . "$_p" && break; done

declare -a CASES=()
for f in $BASE/cases/*.sh; do . "$f"; done

FILTER="$*"
echo "[$(date +%T)] auth suite start, results=$RESULTS, cases=${#CASES[@]}"

for entry in "${CASES[@]}"; do
  IFS='|' read -r id feature ctype desc fn <<< "$entry"
  if [ -n "$FILTER" ]; then
    match=0
    for f in $FILTER; do case "$id" in *"$f"*) match=1;; esac; done
    [ "$match" = "1" ] || continue
  fi
  # 模式过滤：三权分立专项仅在 MODE=separation 下执行；root 豁免用例仅在 normal 下有意义
  if [ "${MODE:-normal}" != "separation" ] && [ "$feature" = "三权分立" ]; then
    echo "[$(date +%T)] skip $id（三权分立专项，仅 separation 模式执行）"
    continue
  fi
  if [ "${MODE:-normal}" = "separation" ] && [ "$id" = "AUTH-026" ]; then
    echo "[$(date +%T)] skip $id（root 豁免用例在 separation 模式下无意义）"
    continue
  fi
  echo "[$(date +%T)] ===== $id | $feature | $ctype | $desc"
  CASE_FAILS=0; CASE_MSGS=""
  out="$RESULTS/$id.out"
  : > "$out"
  log_mark_all
  start=$(date +%s)
  "$fn" >> "$out" 2>&1
  dur=$(( $(date +%s) - start ))
  errs=0
  for ip in $DN_LIST; do
    mark=$(echo "$MARKS" | tr ' ' '\n' | awk -F: -v ip="$ip" '$1==ip{print $2}')
    read -r tot ben <<< "$(log_delta "$ip" "${mark:-0}")"
    errs=$(( errs + ${tot:-0} - ${ben:-0} ))
  done
  [ "$errs" -lt 0 ] && errs=0
  verdict=PASS
  [ "$CASE_FAILS" -gt 0 ] && verdict=FAIL
  [ "$errs" -gt 0 ] && verdict=FAIL
  detail=$(echo "$CASE_MSGS" | cut -c1-360)
  [ "$errs" -gt 0 ] && detail="$detail logERROR=$errs"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$ctype" "$verdict" "$CASE_FAILS" "$errs" "$dur" "$detail" >> "$RES"
  echo "[$(date +%T)] $id -> $verdict (fails=$CASE_FAILS logErr=$errs ${dur}s)"
done

echo "[$(date +%T)] auth suite done"
awk -F'\t' 'NR>1{c[$4]++} END{for(k in c) print k, c[k]}' "$RES"
