#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 —— 性能对比入口（3C5D + iot-benchmark）
#
#   bash tools/run_perf.sh [--set all|write|query|consensus] [--only P-01,P-03]
#                          [--repeat N] [--devices N] [--sensors N] [--loop N]
#
#   与功能用例的关系：**互斥**。性能用例也会"停集群 → 清 data/logs → 写配置 → 启动"，
#   因此必须等 tools/run_all.sh 跑完再跑；本脚本用同一个 flock 文件互斥。
#
#   每个变体都从干净集群开始，跑 iot-benchmark，结果写：
#     results/perf_<P-xx>.csv      每个变体一行（吞吐 / 点数 / AVG / P99 / 耗时 / benchmark CSV 路径）
#     results/<P-xx>_<runid>.out   完整输出
#   判据：与同轮基线比，吞吐下降 > PERF_TOLERANCE_PCT 记 FAIL，0~30% 记 WARN；
#        P99 恶化 > PERF_LATENCY_TOL_PCT 记 FAIL。**不设绝对吞吐门槛**（本环境硬件与文档不同）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SET=all; ONLY=""; REPEAT=""; DEVICES=""; SENSORS=""; LOOP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --devices) DEVICES="$2"; shift 2 ;;
    --sensors) SENSORS="$2"; shift 2 ;;
    --loop) LOOP="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done

OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"
RUN_ID=$(date +%Y%m%d_%H%M%S)
LOCK="$OUTDIR/.run_all.lock"
exec 9>"$LOCK" || exit 1
if ! flock -w 7200 9; then
  echo "!! 有另一个 run_all/run_perf 正在运行（功能用例与性能用例互斥），本次退出。" >&2
  exit 2
fi
printf 'pid=%s perf set=%s only=%s start=%s\n' "$$" "$SET" "$ONLY" "$(date '+%F %T')" >&9

export PERF_REPEAT="${REPEAT:-${PERF_REPEAT:-1}}"
[ -n "$DEVICES" ] && export PERF_DEVICES="$DEVICES"
[ -n "$SENSORS" ] && export PERF_SENSORS="$SENSORS"
[ -n "$LOOP" ] && export PERF_LOOP="$LOOP"

SUITE="$OUTDIR/PERF_${SET}_${RUN_ID}.out"
: >"$SUITE"
log(){ printf '%s\n' "$*" | tee -a "$SUITE"; }

ALL="P-01 P-02 P-03 P-04 P-05"
in_set(){ local id=$1
  case "$SET" in
    all) return 0 ;;
    write)     case "$id" in P-01|P-02|P-03) return 0;; *) return 1;; esac ;;
    query)     case "$id" in P-04) return 0;; *) return 1;; esac ;;
    consensus) case "$id" in P-05) return 0;; *) return 1;; esac ;;
    quick)     case "$id" in P-01|P-05) return 0;; *) return 1;; esac ;;
    *) return 1 ;;
  esac
}
in_only(){ local id=$1
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$id,"*) return 0;; *) return 1;; esac
}
case_file(){ local id=$1 low
  low=$(printf '%s' "$id" | tr 'A-Z' 'a-z' | tr '-' '_')
  ls "$SKILL"/cases/perf/${low}_*.sh 2>/dev/null | head -1
}

log "=== 性能对比 set=$SET only=${ONLY:-<全部>} repeat=$PERF_REPEAT devices=${PERF_DEVICES:-默认} sensors=${PERF_SENSORS:-默认} loop=${PERF_LOOP:-默认} run_id=$RUN_ID ==="

total=0; passn=0; failn=0
for id in $ALL; do
  in_set "$id" && in_only "$id" || continue
  f=$(case_file "$id")
  [ -z "$f" ] && { log "!! 找不到性能用例 $id"; failn=$((failn+1)); continue; }
  total=$((total+1))
  log ""
  log "########## [$id] $(basename "$f") ##########"
  caselog="$OUTDIR/.perf_${id}_${RUN_ID}.tmp"
  bash "$f" >"$caselog" 2>&1
  rc=$?
  cat "$caselog"
  cat "$caselog" | tee -a "$SUITE" >/dev/null
  rm -f "$caselog"
  r=$(grep -hoE 'RESULT (PASS|FAIL)' "$SUITE" | tail -1 | awk '{print $2}')
  if [ "$r" = "PASS" ]; then passn=$((passn+1)); else failn=$((failn+1)); log "!! [$id] 判为 FAIL（rc=$rc）"; fi
done

log ""
log "=== 性能汇总: 执行=$total PASS=$passn FAIL=$failn ==="
for f in "$OUTDIR"/perf_P-*.csv; do
  [ -f "$f" ] || continue
  log "--- $(basename "$f") ---"
  cat "$f" | tee -a "$SUITE"
done | tail -60
log "套件输出: $SUITE"
[ "$failn" -eq 0 ] || exit 1
