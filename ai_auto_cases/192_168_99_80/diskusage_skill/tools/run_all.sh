#!/bin/bash
# ============================================================================
# 磁盘占用统计 skill —— 用例集合入口
#   bash tools/run_all.sh [--set quick|gate|stats|all] [--only DU-01,DU-03]
#                         [--consensus IoTConsensus|IoTConsensusV2] [--ver <版本目录名>]
#   说明：每条用例自己负责 清集群/写配置/启动（串行执行，互不干扰）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SET=all; ONLY=""; CONSENSUS=""; VER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --consensus) CONSENSUS="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done
. "$SKILL/conf/env.conf"
[ -n "$VER" ] && { V_TESTDB="$VER"; BUILD_TAG="$VER"; }
[ -n "$CONSENSUS" ] && DATA_CONSENSUS="$CONSENSUS"
export V_TESTDB BUILD_TAG DATA_CONSENSUS

RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"
SUITE="$OUTDIR/SUITE_${SET}_${RUN_ID}.out"
CSV="$OUTDIR/test_result.csv"
[ -f "$CSV" ] || echo 'Time,build,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$CSV"

# 集合定义
case_in_set(){
  local id=$1
  case "$SET" in
    gate)  case "$id" in DU-01|DU-02) return 0;; *) return 1;; esac ;;
    stats) case "$id" in DU-03|DU-04|DU-05) return 0;; *) return 1;; esac ;;
    quick) case "$id" in DU-01|DU-03) return 0;; *) return 1;; esac ;;
    all)   return 0 ;;
    *)     return 0 ;;
  esac
}

mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
echo "=== 磁盘占用统计 skill 用例集 set=$SET build=$V_TESTDB consensus=$DATA_CONSENSUS $(date '+%F %T') ===" | tee "$SUITE"
PASS=0; FAIL=0; SKIP=0
for line in "${LINES[@]}"; do
  IFS=$'\t' read -r id script model gran restart params desc <<<"$line"
  if ! case_in_set "$id"; then SKIP=$((SKIP+1)); continue; fi
  if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$id,"; then SKIP=$((SKIP+1)); continue; fi
  echo "" | tee -a "$SUITE"
  echo "########## [$id] $desc —— $(date '+%F %T') ##########" | tee -a "$SUITE"
  T0=$(date +%s)
  bash "$SKILL/$script" ${CONSENSUS:+--consensus "$CONSENSUS"} </dev/null >"$OUTDIR/${id}_${RUN_ID}.out" 2>&1
  rc=$?
  T1=$(date +%s); EL=$((T1-T0))
  RES=$(grep -aE '^\[[^]]*\] RESULT ' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1)
  STATUS=$(printf '%s' "$RES" | grep -oE 'RESULT (PASS|FAIL)' | awk '{print $2}')
  FF=$(printf '%s' "$RES" | grep -oE 'fail_flag=[0-9]+' | cut -d= -f2)
  MSG=$(grep -aE '^\[[^]]*\] v_warnMessage=' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1 | sed 's/.*v_warnMessage=//' | tr ',' ';' | tr -d "'")
  [ -z "$STATUS" ] && STATUS="UNKNOWN"
  [ "$STATUS" = "PASS" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  echo "  -> rc=$rc [$STATUS] fail_flag=${FF:-?} elapsed=${EL}s 输出=$OUTDIR/${id}_${RUN_ID}.out" | tee -a "$SUITE"
  [ -n "$MSG" ] && echo "     message: ${MSG:0:200}" | tee -a "$SUITE"
  printf '%s,%s,%s,%s,%s,%s,%s,\047%s\047\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "$id" "$STATUS" "$EL" "${FF:-}" "$OUTDIR/${id}_${RUN_ID}.out" "$MSG" >>"$CSV"
done
echo "" | tee -a "$SUITE"
echo "=== 汇总 $(date '+%F %T') ===" | tee -a "$SUITE"
echo "PASS=$PASS FAIL=$FAIL 跳过=$SKIP ；明细 CSV：$CSV" | tee -a "$SUITE"
echo "套件输出：$SUITE"
