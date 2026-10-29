#!/bin/bash
# ============================================================================
# 合并（compaction）专项 skill —— 用例集合入口
#   bash tools/run_all.sh [--set smoke|basic|param|param2|scene|perf|remove|ttl|combo|repair|scale|dtype|ha|official|regression|quick|all]
#                         [--only CO-01,CO-03]
#   regression = 发版回归冻结清单（cases/regression.txt，51 条）；quick = hotfix 快速门禁（cases/quick.txt，8 条）
#                         [--consensus IoTConsensus|IoTConsensusV2] [--ver <版本目录名>]
#   每条用例自己负责 清集群/写配置/启动，串行执行（并行会互相污染 TsFile 与日志计数）。
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

# ---------------------------------------------------------------------------
# 并发保护：两个 run_all 同时跑会互相 清 data/启停节点，必然产生假 FAIL
#（2026-10-12 CO-02 就是这么被 CO-03 的集群清理打成 "550: Table does not exist"）。
# 用 flock 非阻塞加锁，拿不到锁直接退出。
# ---------------------------------------------------------------------------
LOCK="$OUTDIR/.run_all.lock"
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
  echo "!! 已有另一个 run_all.sh 正在运行（锁 $LOCK，持有者：$(head -c 200 "$LOCK" 2>/dev/null)），本次退出。" >&2
  echo "   并发跑会互相清库/启停节点，产生假 FAIL；请等它结束或先 kill。" >&2
  exit 2
fi
printf 'pid=%s set=%s only=%s start=%s\n' "$$" "$SET" "$ONLY" "$(date '+%F %T')" >&9

SUITE="$OUTDIR/SUITE_${SET}_${RUN_ID}.out"
CSV="$OUTDIR/test_result.csv"
[ -f "$CSV" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$CSV"

case_in_set(){ local id=$1
  case "$SET" in
    smoke)  case "$id" in CO-01|CO-02|CO-03|CO-04|CO-05|CO-06|CO-07|CO-08) return 0;; *) return 1;; esac ;;
    basic)  case "$id" in CO-0[1-8]) return 0;; *) return 1;; esac ;;
    param)  case "$id" in CO-09|CO-10) return 0;; *) return 1;; esac ;;
    perf)   case "$id" in CO-11) return 0;; *) return 1;; esac ;;
    remove) case "$id" in CO-12) return 0;; *) return 1;; esac ;;
    ttl)    case "$id" in CO-13|CO-14) return 0;; *) return 1;; esac ;;
    combo)  case "$id" in CO-15|CO-16|CO-17) return 0;; *) return 1;; esac ;;
    param2) case "$id" in CO-18|CO-19|CO-20|CO-21|CO-22|CO-23|CO-24|CO-25|CO-26|CO-32) return 0;; *) return 1;; esac ;;
    scene)  case "$id" in CO-27|CO-28|CO-29|CO-30|CO-31) return 0;; *) return 1;; esac ;;
    dtype)  case "$id" in DT-01|DT-02|DT-03|DT-04|DT-05|DT-06|DT-07) return 0;; *) return 1;; esac ;;
    ha)     case "$id" in DT-08|DT-09) return 0;; *) return 1;; esac ;;
    repair) case "$id" in CO-33) return 0;; *) return 1;; esac ;;
    scale)  case "$id" in CO-34) return 0;; *) return 1;; esac ;;
    # official：按官方《软件测试文档》+ 设计文档补齐的用例（CO-35 起，见 docs/OFFICIAL_COVERAGE.md）
    official) case "$id" in CO-3[5-9]|CO-4[0-9]) return 0;; *) return 1;; esac ;;
    # regression：发版回归的**冻结清单**（cases/regression.txt，51 条）——新增试验性用例只进 all/official，
    #             在某个版本上验证通过后才并入本清单（保证"跑回归"的含义稳定、可复现）
    regression) grep -qx "$id" "$SKILL/cases/regression.txt" 2>/dev/null ;;
    # quick：hotfix 快速门禁（cases/quick.txt，约 1.5~1.7h）——合并主链路 + 改类型主链路 + 修复链路
    quick)  grep -qx "$id" "$SKILL/cases/quick.txt" 2>/dev/null ;;
    all)    return 0 ;;
    *)      return 0 ;;
  esac
}
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
echo "=== 合并专项用例集 set=$SET build=$V_TESTDB consensus=$DATA_CONSENSUS $(date '+%F %T') ===" | tee "$SUITE"
PASS=0; FAIL=0; SKIP=0
for line in "${LINES[@]}"; do
  IFS=$'\t' read -r id script model gran restart params desc <<<"$line"
  case_in_set "$id" || { SKIP=$((SKIP+1)); continue; }
  if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$id,"; then SKIP=$((SKIP+1)); continue; fi
  echo "" | tee -a "$SUITE"
  echo "########## [$id] $desc —— $(date '+%F %T') ##########" | tee -a "$SUITE"
  T0=$(date +%s)
  bash "$SKILL/$script" ${CONSENSUS:+--consensus "$CONSENSUS"} </dev/null >"$OUTDIR/${id}_${RUN_ID}.out" 2>&1
  rc=$?; T1=$(date +%s); EL=$((T1-T0))
  RES=$(grep -aE '^\[[^]]*\] RESULT ' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1)
  STATUS=$(printf '%s' "$RES" | grep -oE 'RESULT (PASS|FAIL)' | awk '{print $2}')
  FF=$(printf '%s' "$RES" | grep -oE 'fail_flag=[0-9]+' | cut -d= -f2)
  MSG=$(grep -aE '^\[[^]]*\] v_warnMessage=' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1 | sed 's/.*v_warnMessage=//' | tr '\n\r' '  ' | tr -s ' ' | tr ',' ';' | tr -d "'" | cut -c1-1200)
  [ -z "$STATUS" ] && STATUS="UNKNOWN"
  [ "$STATUS" = "PASS" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  echo "  -> rc=$rc [$STATUS] fail_flag=${FF:-?} elapsed=${EL}s 输出=$OUTDIR/${id}_${RUN_ID}.out" | tee -a "$SUITE"
  [ -n "$MSG" ] && echo "     message: ${MSG:0:220}" | tee -a "$SUITE"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,\047%s\047\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${DATA_CONSENSUS}" "$id" "$STATUS" "$EL" "${FF:-}" "$OUTDIR/${id}_${RUN_ID}.out" "$MSG" >>"$CSV"
done
echo "" | tee -a "$SUITE"
echo "=== 汇总 $(date '+%F %T')：PASS=$PASS FAIL=$FAIL 跳过=$SKIP ===" | tee -a "$SUITE"
echo "明细 CSV：$CSV"
echo "套件输出：$SUITE"
