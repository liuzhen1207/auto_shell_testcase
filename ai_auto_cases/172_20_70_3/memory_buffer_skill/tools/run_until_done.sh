#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 —— "跑到出结果为止" 的监督器
#
#   背景：本环境（172.20.70.3）上长跑用例会**偶发被 SIGKILL**（约 1/3 概率，见 KNOWN_ISSUES），
#   表现为 `run_serial.sh: line N: PID Killed`，用例来不及写 result 文件。
#   已排除：OOM（dmesg/journal 无记录、可用内存 25G）、cgroup 限制、systemd-oomd、cron 巡检。
#   与其继续追根因，这里做**用例级重试**：单条用例独立起一个 run_serial 进程，
#   没产出 result 文件就重跑，直到出结果或用尽次数。配合 `--resume` 不会重复跑已 PASS 的用例。
#
#   bash tools/run_until_done.sh [--set ...] [--only ...] [--tries N]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SET=regression; ONLY=""; CONSENSUS=""; VER=""; TRIES=4; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --consensus) CONSENSUS="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    --tries) TRIES="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done

OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.tsv"
# --fresh：清空 summary（只留表头）。用于"换版本重新跑一整轮"——
# 否则上一轮的同名记录会让 have_result() 误判"已产出结论"，把本轮被 kill 的用例直接记为 FAIL。
if [ "$FRESH" = "1" ]; then
  printf 'time\tcase\tbuild\tconsensus\tresult\tfailCount\telapsed_s\trc\tnote\n' >"$SUMMARY"
  rm -f "$OUTDIR"/result_MB-*.txt "$OUTDIR"/result_P-*.txt
  echo "=== --fresh：已清空 summary 与旧 result 文件 ==="
fi

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
# 判定"这条用例是否真的产出了结论"：**以 result 文件为准**，不看 summary。
#   ⚠️ 关键 bug（已修）：首版查 summary 里有没有非空 result 字段，
#   但 run_serial 在用例被 SIGKILL、没写 result 文件时也会往 summary 追加一行
#   `result=FAIL / note=no-result`。于是 have_result() 立刻为真 ⇒ 重试逻辑形同虚设，
#   用例被 kill 一次就直接记 FAIL，白白丢掉"再跑一次就能过"的机会（MB-02 就这样被误判）。
have_result(){ local id=$1
  ls "$OUTDIR"/result_${id}_*.txt >/dev/null 2>&1
}
already_pass(){ local id=$1
  awk -F'\t' -v id="$id" '$2==id && $5=="PASS"{found=1} END{exit !(found)}' "$SUMMARY" 2>/dev/null
}
last_result(){ local id=$1
  awk -F'\t' -v id="$id" '$2==id{r=$5} END{print r}' "$SUMMARY" 2>/dev/null
}

echo "=== run_until_done set=$SET only=${ONLY:-<全部>} tries=$TRIES ==="
for id in $ALL_CASES; do
  in_set "$id" && in_only "$id" || continue
  if already_pass "$id"; then echo "--- [$id] 已 PASS，跳过"; continue; fi
  n=0
  while [ "$n" -lt "$TRIES" ]; do
    n=$((n+1))
    echo ""
    echo ">>>>>>>>>> [$id] 第 $n/$TRIES 次尝试 $(date '+%F %T') <<<<<<<<<<"
    args=(--set "$SET" --only "$id")
    [ -n "$CONSENSUS" ] && args+=(--consensus "$CONSENSUS")
    [ -n "$VER" ] && args+=(--ver "$VER")
    bash "$HERE/run_serial.sh" "${args[@]}" 9>&- || true
    if have_result "$id"; then
      echo ">>> [$id] 已产出结论：$(last_result "$id")（第 $n 次尝试）"
      break
    fi
    echo "!! [$id] 第 $n 次仍未产出 result 文件，10s 后重试"
    sleep 10
  done
  have_result "$id" || echo "!!! [$id] 连续 $TRIES 次都没跑出结果，标记为环境阻塞"
done

echo ""
echo "=== 最终汇总 ==="
column -t -s$'\t' "$SUMMARY" 2>/dev/null | tail -40 || tail -40 "$SUMMARY"
