#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 —— 串行驱动（**推荐用于长跑**）
#
#   bash tools/run_serial.sh [--set quick|doc|ha|regression|all] [--only MB-01,MB-03]
#                            [--consensus IoTConsensus|IoTConsensusV2] [--ver <dir>]
#                            [--resume]      # 跳过 results/summary 里已 PASS 的用例
#                            [--max-retry N] # 单条用例失败/被杀后的重试次数（默认 1）
#
#   与 tools/run_all.sh 的差别（都是同一批用例、同一套 lib）：
#     1. 用例**前台执行**，不套 setsid、不切 fd —— 避免"父进程被 SIGKILL、用例变成孤儿继续跑"
#        导致相邻用例互相踩集群（实测踩过：MB-02 被判 FAIL，其实它还在后台跑，MB-03 已经开跑）；
#     2. 用 `pgrep -f` 判断存活（`ps -o args` 会按宽度截断长路径，导致误判"进程已退出"）；
#     3. 每条用例前清理 **PPID==1 的孤儿用例**（只杀孤儿，不碰本轮）；
#     4. 支持 `--resume`：从上次结果里跳过已 PASS 的用例，长跑中断后不用从头再来；
#     5. 每条用例结束立刻把结论追加到 `results/summary.tsv` 并打印，便于随时看进度。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SET=all; ONLY=""; CONSENSUS=""; VER=""; RESUME=0; MAX_RETRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --consensus) CONSENSUS="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --max-retry) MAX_RETRY="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done

OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"
RUN_ID=$(date +%Y%m%d_%H%M%S)
LOCK="$OUTDIR/.run_serial.lock"
exec 9>"$LOCK" || exit 1
if ! flock -w 21600 9; then
  echo "!! 另一个 run_serial/run_perf 正在运行，本次退出。" >&2
  exit 2
fi
printf 'pid=%s set=%s start=%s\n' "$$" "$SET" "$(date '+%F %T')" >&9

SUMMARY="$OUTDIR/summary.tsv"
[ -f "$SUMMARY" ] || printf 'time\tcase\tbuild\tconsensus\tresult\tfailCount\telapsed_s\trc\tnote\n' >"$SUMMARY"

ALL_CASES="MB-01 MB-02 MB-03 MB-04 MB-05 MB-06 MB-07 MB-08 MB-09 MB-10 MB-16 MB-18 MB-12 MB-17 MB-13 MB-15 MB-11 MB-14 MB-19"
in_set(){ local id=$1
  case "$SET" in
    all|regression) return 0 ;;
    quick) case "$id" in MB-01|MB-03|MB-06|MB-10|MB-18) return 0;; *) return 1;; esac ;;
    doc)   case "$id" in MB-05|MB-11|MB-12|MB-15|MB-16|MB-17|MB-18) return 0;; *) return 1;; esac ;;
    ha)    case "$id" in MB-08|MB-10|MB-13) return 0;; *) return 1;; esac ;;
    neg)   case "$id" in MB-19) return 0;; *) return 1;; esac ;;
    *) return 1 ;;
  esac
}
in_only(){ local id=$1
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$id,"*) return 0;; *) return 1;; esac
}
case_file(){ local id=$1 low
  low=$(printf '%s' "$id" | tr 'A-Z' 'a-z' | tr '-' '_')
  ls "$SKILL"/cases/common/${low}_*.sh 2>/dev/null | head -1
}
# 只杀 PPID==1 的孤儿用例（上一轮被中断后残留），绝不碰本轮
kill_orphans(){
  local p
  p=$(ps -eww -o pid=,ppid=,args= 2>/dev/null | awk -v me=$$ '$2==1 && /membuf_skill\/cases\/common\/mb_/ && $1!=me {print $1}')
  if [ -n "$p" ]; then
    echo "!! 清理孤儿用例进程: $(echo $p | tr '\n' ' ')"
    kill -9 $p 2>/dev/null || true
    sleep 3
  fi
}
case_alive(){ pgrep -f "membuf_skill/cases/common/$(basename "$1")" >/dev/null 2>&1; }
prev_result(){ local id=$1
  [ "$RESUME" = "1" ] || { echo ""; return; }
  awk -F'\t' -v id="$id" '$2==id && $5=="PASS"{r="PASS"} END{print r}' "$SUMMARY" 2>/dev/null
}

echo "=== 串行驱动 set=$SET only=${ONLY:-<全部>} consensus=${CONSENSUS:-<env>} ver=${VER:-<env>} resume=$RESUME run_id=$RUN_ID ==="

total=0; passn=0; failn=0; skipn=0; nores=0
for id in $ALL_CASES; do
  in_set "$id" && in_only "$id" || continue
  if [ "$(prev_result "$id")" = "PASS" ]; then
    echo "--- [$id] 已 PASS（resume 跳过）"
    skipn=$((skipn+1)); continue
  fi
  f=$(case_file "$id")
  [ -z "$f" ] && { echo "!! 找不到用例 $id"; failn=$((failn+1)); continue; }

  total=$((total+1))
  args=()
  [ -n "$CONSENSUS" ] && args+=(--consensus "$CONSENSUS")
  [ -n "$VER" ] && args+=(--ver "$VER")

  attempt=0; verdict=""; rc_final=0
  while [ "$attempt" -le "$MAX_RETRY" ]; do
    attempt=$((attempt+1))
    kill_orphans
    rm -f "$OUTDIR"/result_${id}_*.txt 2>/dev/null || true
    echo ""
    echo "########## [$id] $(basename "$f") （第 $attempt 次）########## $(date '+%F %T')"
    # 前台执行，输出直接可见（同时由外层 tee 落盘）
    bash "$f" ${args[@]+"${args[@]}"} 9>&-
    rc_final=$?
    rf=$(ls -t "$OUTDIR"/result_${id}_*.txt 2>/dev/null | head -1)
    # 被 SIGKILL 时先分辨两种情况：用例仍在跑（孤儿，等它收尾） vs 真的死了（重试）
    if [ "$rc_final" -eq 137 ] && [ -z "$rf" ]; then
      if case_alive "$f"; then
        echo "!! [$id] 被 SIGKILL 但进程仍在，等其自行收尾（最多 30min）"
        for _ in $(seq 1 180); do
          rf=$(ls -t "$OUTDIR"/result_${id}_*.txt 2>/dev/null | head -1)
          [ -n "$rf" ] && break
          case_alive "$f" || break
          sleep 10
        done
      else
        echo "!! [$id] 被 SIGKILL(rc=137) 且进程已退出、无 result 文件"
      fi
      if [ -z "$rf" ]; then
        echo "!! [$id] 重试（第 $((attempt+1)) 次）"
        sleep 5; continue
      fi
    fi
    if [ -n "$rf" ]; then
      verdict=$(awk -F= '/^result=/{print $2}' "$rf" 2>/dev/null)
      break
    fi
    echo "!! [$id] 未产出 result 文件（rc=$rc_final），重试"
    sleep 5
  done

  rf=$(ls -t "$OUTDIR"/result_${id}_*.txt 2>/dev/null | head -1)
  fcount=$([ -n "$rf" ] && awk -F= '/^fail_flag=/{print $2}' "$rf" 2>/dev/null || echo "-")
  el=$([ -n "$rf" ] && awk -F= '/^elapsed_seconds=/{print $2}' "$rf" 2>/dev/null || echo "-")
  # 没有 result 文件 ⇒ 记为 NO_RESULT（环境原因，用例本身没下结论），
  # 不要写成 FAIL —— 那会让统计把"环境打断"算成"用例失败"。
  [ -z "$verdict" ] && verdict="NO_RESULT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date --iso-8601=seconds)" "$id" "${BUILD_TAG:-$VER}" "${CONSENSUS:-IoTConsensus}" \
    "$verdict" "${fcount:--}" "${el:--}" "$rc_final" "$([ -n "$rf" ] && basename "$rf" || echo "no-result")" >>"$SUMMARY"
  echo ">>> [$id] $verdict  failCount=$fcount  elapsed=${el}s  rc=$rc_final"
  case "$verdict" in
    PASS) passn=$((passn+1)) ;;
    NO_RESULT) nores=$((nores+1)) ;;
    *) failn=$((failn+1)) ;;
  esac
done

echo ""
echo "=== 汇总: 执行=$total PASS=$passn FAIL=$failn NO_RESULT=$nores 跳过（resume）=$skipn ==="
echo "=== 明细 ==="
column -t -s$'\t' "$SUMMARY" 2>/dev/null | tail -30 || tail -30 "$SUMMARY"
echo "结果文件: $SUMMARY"
echo "CSV: $OUTDIR/test_result.csv"
[ "$failn" -eq 0 ] || exit 1
