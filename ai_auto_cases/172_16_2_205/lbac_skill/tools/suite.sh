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

# ---------- 每个用例的 CN/DN 日志窗口扫描 ----------
declare -A LOGPOS=()
NOISE_RE='Ratis|GrpcLogAppender|HEARTBEAT|UPDATE_REGION_ROUTE_MAP|RouteBalancer|ScheduledExecutorUtil|openSession|Fail to start server|already exist|AppendEntries|appendEntries|INCONSISTENCY|Follower failed|leader|borrow|Pipe|Template .* does not exist|ConsensusPipe|Cannot find IOTDB_HOME|Couldn.t load the configuration|License has not been set|password expiration'

init_logpos() {
  local ip
  for ip in $CN_LIST; do LOGPOS["CN$ip"]=${LOGSTART["CN$ip"]:-0}; done
  for ip in $DN_LIST; do LOGPOS["DN$ip"]=${LOGSTART["DN$ip"]:-0}; done
}

scan_case_logs() {  # $1=用例 id；输出 "err=N warn=N unexp=N"
  local id=$1 f="$RESULTS/$1.logwin.txt" ip role dir prev resp total lines unexp=0 err=0 warn=0
  : > "$f"
  for ip in $CN_LIST $DN_LIST; do
    case "$ip" in
      172.16.2.26|172.16.2.27|172.16.2.28) role=CN; dir=$CN_DIR ;;
      *) role=DN; dir=$DN_DIR ;;
    esac
    prev=${LOGPOS["$role$ip"]:-0}
    resp=$(ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((prev + 1)) $dir/logs/log_$(echo $role | tr 'A-Z' 'a-z')_all.log 2>/dev/null | grep -E ' (ERROR|WARN) '; echo __TOTAL__\$(wc -l < $dir/logs/log_$(echo $role | tr 'A-Z' 'a-z')_all.log 2>/dev/null)" 2>/dev/null)
    total=$(echo "$resp" | sed -n 's/^__TOTAL__//p' | tail -1)
    lines=$(echo "$resp" | grep -v '^__TOTAL__')
    if [ -n "$lines" ]; then
      echo "$lines" | sed "s/^/[$role $ip] /" >> "$f"
      err=$((err + $(echo "$lines" | grep -c ' ERROR ')))
      warn=$((warn + $(echo "$lines" | grep -c ' WARN ')))
      unexp=$((unexp + $(echo "$lines" | grep -vEi "$NOISE_RE" | grep -c .)))
    fi
    if [ -n "$total" ]; then LOGPOS["$role$ip"]=$total; fi
  done
  echo "err=$err warn=$warn unexp=$unexp"
}

run_one() {
  local id=$1 feature=$2 type=$3 desc=$4 fn=$5
  local t0 t1 dur out verdict detail
  t0=$(date +%s)
  FAILS=0
  out="$RESULTS/$id.out"
  { echo "===== $id | $desc"; "$fn"; } > "$out" 2>&1
  t1=$(date +%s); dur=$((t1 - t0))
  local logstat=""
  logstat=$(scan_case_logs "$id" 2>/dev/null || true)
  detail=$(grep -E '^\s+\[FAIL\]' "$out" | head -3 | tr '\n' ' ' | cut -c1-300)
  case "$logstat" in *"unexp=0"*) ;; *) [ -n "$logstat" ] && detail="$detail LOG{$logstat}" ;; esac
  if grep -qE '^\s+\[FAIL\]' "$out"; then
    if [ -n "${KNOWN_MAP[$id]:-}" ]; then verdict=KNOWN; else verdict=FAIL; fi
  else
    verdict=PASS
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$feature" "$type" "$verdict" "$FAILS" "$dur" "$detail" >> "$RES"
  echo "[$(date '+%T')] $id -> $verdict (${dur}s) $(echo "$desc" | cut -c1-40)"
  grep -E '^\s+\[FAIL\]' "$out" | head -3 | sed 's/^/        /'
}

init_logpos
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
