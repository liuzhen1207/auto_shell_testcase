#!/bin/bash
# ============================================================================
# LBAC 套件运行器
#   usage: suite.sh [case-id ...]      不传则跑全部
#   环境变量：NEW / SKIP_OF / ONLY / LIST
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$BASE/conf/env.conf"
. "$BASE/lib/lib_lbac.sh"

declare -A SKIP_OF=()
declare -A SLOW_OF=()
declare -a CASES=()
for f in "$BASE"/cases/*.sh; do . "$f"; done

RESULTS="${RESULT_BASE:-$BASE/results}/run_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS"
RES="$RESULTS/results.tsv"
printf 'id\tfeature\ttype\tverdict\tfails\tdur_s\tdetail\n' > "$RES"

FILTER="$*"
echo "[$(date '+%T')] LBAC suite start（SEP=${SEP:-0}）, results=$RESULTS, cases=${#CASES[@]}"

declare -A KNOWN_MAP=()
if [ -f "$KNOWN" ]; then
  while IFS='|' read -r kid _reason; do
    [ -z "$kid" ] && continue
    case "$kid" in \#*) continue;; esac
    KNOWN_MAP["$kid"]=1
  done < "$KNOWN"
fi

# 运行前记日志行数（用于整轮日志扫描）
declare -A LOGSTART=()
for ip in $CN_LIST; do
  LOGSTART["CN$ip"]=$(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < $CN_DIR/logs/log_confignode_all.log" 2>/dev/null)
done
for ip in $DN_LIST; do
  LOGSTART["DN$ip"]=$(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < $DN_DIR/logs/log_datanode_all.log" 2>/dev/null)
done

run_one() {
  local id=$1 feature=$2 type=$3 desc=$4 fn=$5
  local t0 t1 dur out verdict detail
  t0=$(date +%s)
  FAILS=0
  out="$RESULTS/$id.out"
  { echo "===== $id | $desc"; "$fn"; } > "$out" 2>&1
  t1=$(date +%s); dur=$((t1 - t0))
  detail=$(grep -E '^\s+\[FAIL\]' "$out" | head -3 | tr '\n' ' ' | cut -c1-300)
  if grep -qE '^\s+\[FAIL\]' "$out"; then
    if [ -n "${KNOWN_MAP[$id]:-}" ]; then verdict=KNOWN; else verdict=FAIL; fi
  else
    verdict=PASS
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$type" "$verdict" "$FAILS" "$dur" "$detail" >> "$RES"
  echo "[$(date '+%T')] $id -> $verdict (${dur}s) $(echo "$desc" | cut -c1-40)"
  grep -E '^\s+\[FAIL\]' "$out" | head -3 | sed 's/^/        /'
}

for c in "${CASES[@]}"; do
  IFS='|' read -r id feature type desc fn <<< "$c"
  if [ -n "$FILTER" ]; then
    match=0
    for f in $FILTER; do case "$id" in *"$f"*) match=1;; esac; done
    [ "$match" = "0" ] && continue
  fi
  if [ -n "${SKIP_OF[$id]:-}" ]; then
    printf '%s\t%s\t%s\tSKIP\t0\t0\t%s\n' "$id" "$feature" "$type" "${SKIP_OF[$id]}" >> "$RES"
    echo "[$(date '+%T')] $id -> SKIP (${SKIP_OF[$id]})"
    continue
  fi
  case "$id" in
    *SLOW*) : ;;
  esac
  run_one "$id" "$feature" "$type" "$desc" "$fn"
done

# ---------------- 汇总 ----------------
echo "[$(date '+%T')] ===== 汇总 ====="
awk -F'\t' 'NR>1{c[$4]++} END{for (k in c) printf "%s %d\n", k, c[k]}' "$RES" | sort
echo "结果：$RES"

# ---------------- 整轮日志扫描 ----------------
SCAN="$RESULTS/log_scan.txt"
: > "$SCAN"
for ip in $CN_LIST; do
  start=${LOGSTART["CN$ip"]:-0}; start=${start:-0}
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) $CN_DIR/logs/log_confignode_all.log 2>/dev/null | grep -E ' (ERROR|WARN) '" 2>/dev/null | sed "s/^/[CN $ip] /" >> "$SCAN"
done
for ip in $DN_LIST; do
  start=${LOGSTART["DN$ip"]:-0}; start=${start:-0}
  ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((start+1)) $DN_DIR/logs/log_datanode_all.log 2>/dev/null | grep -E ' (ERROR|WARN) '" 2>/dev/null | sed "s/^/[DN $ip] /" >> "$SCAN"
done
total=$(wc -l < "$SCAN")
noise=$(grep -cEi 'Ratis|GrpcLogAppender|HEARTBEAT|UPDATE_REGION_ROUTE_MAP|RouteBalancer|ScheduledExecutorUtil|openSession|Fail to start server|already exist|AppendEntries|appendEntries|INCONSISTENCY|Follower failed|leader|borrow|Pipe|Template .* does not exist' "$SCAN" || true)
echo "[$(date '+%T')] 日志扫描：总计 $total 行，噪声(已知) $noise 行，疑似异常 $((total - noise)) 行"
echo "  明细：$SCAN"
