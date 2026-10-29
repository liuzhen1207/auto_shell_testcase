#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 skill —— 用例集合入口
#   bash tools/run_all.sh [--set quick|regression|ha|all] [--only MB-01,MB-03]
#                         [--consensus IoTConsensus|IoTConsensusV2] [--ver <版本目录名>]
#   每条用例自己负责"停集群 → 清 data/logs → 写配置 → 启动 → 执行 → 收尾"，
#   必须串行（并发会互相清库/抢端口，产生假 FAIL）。内置 flock 等锁。
#
#   ⚠️ 在 172.20.70.3 上**不要用 `setsid nohup ... &` 远程投后台再断开 ssh**：
#      实测这样启动的用例会在写入阶段被 SIGKILL（rc=137），而同样的命令在
#      "保持 ssh 会话存活"的前台运行方式下 100% 正常。稳妥做法二选一：
#        ① 用 screen/tmux：`screen -dmS mb bash tools/run_all.sh --set regression`
#        ② 让发起端 ssh 一直挂着（例如本地 `ssh cluster@172.20.70.3 'bash -s' < run.sh` 不中断）
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

RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"
LOCK="$OUTDIR/.run_all.lock"
exec 9>"$LOCK" || exit 1
# 拿不到锁时先等一会儿（默认 600s），避免"上一个刚跑完/正常收尾"被误判成并发
LOCK_WAIT="${LOCK_WAIT:-600}"
if ! flock -w "$LOCK_WAIT" 9; then
  echo "!! 已有另一个 run_all.sh 正在运行（等锁 ${LOCK_WAIT}s 仍未释放），本次退出。文件：$LOCK" >&2
  exit 2
fi
printf 'pid=%s set=%s only=%s start=%s\n' "$$" "$SET" "$ONLY" "$(date '+%F %T')" >&9

# ---------------------------------------------------------------------------
# 清理**孤儿**用例进程（PPID==1 的 mb_xx.sh）
#
# 这是本 skill 最重要的稳定性修复。实测因果链：
#   ① 上一轮 run_all 被中断/强杀（Ctrl-C、ssh 断开、外部清理）时，正在执行的用例会
#      脱离父进程变成孤儿（PPID=1）继续跑：它仍在"停集群/写数据/查一致性"；
#   ② 下一轮 run_all 启动的新用例与这个孤儿**同时**操作同一个集群 ——
#      孤儿在 cluster_stop，新用例在 cluster_start；孤儿在写库，新用例在 clean data。
#   ③ 表现为新用例莫名 `Killed`（rc=137）、写入语句成功数=0、点数对不上、集群起不来。
# 实测证据：清理前有 `PPID=1、etime=04:35 的 mb_06_reject_and_recover.sh` 两个进程，
#   清掉之后再跑同一用例即恢复正常。
#
# 清理条件**只匹配 PPID==1**，绝不动本轮 run_all 自己拉起的用例（它们的 PPID 是 $$），
# 所以不会重犯"pkill 误杀本轮用例"的错。
# ---------------------------------------------------------------------------
cleanup_orphans(){
  local orphans
  orphans=$(ps -eo pid,ppid,args | awk -v me=$$ '$2 == 1 && /membuf_skill\/cases\/common\/mb_[0-9]+_/ && !/awk/ {print $1}')
  if [ -n "$orphans" ]; then
    echo "!! 检测到孤儿用例进程（PPID=1，上一轮残留）：$(echo $orphans | tr '\n' ' ')"
    echo "   它们会与本轮用例抢同一个集群，先清理再开始"
    kill -9 $orphans 2>/dev/null || true
    sleep 2
  fi
  rm -f "$OUTDIR/.run_all.lock.stale"
}
cleanup_orphans


CSV="$OUTDIR/test_result.csv"
[ -f "$CSV" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$CSV"

# 顺序即执行顺序：MB-14 会切协议，放最后；MB-13 会停节点，放倒数第二
# 顺序即执行顺序：会切协议/切 enable_separate_data/切算法的放后面，减少集群启停次数
ALL_CASES="MB-01 MB-02 MB-03 MB-04 MB-05 MB-06 MB-07 MB-08 MB-09 MB-10 MB-16 MB-18 MB-12 MB-17 MB-13 MB-15 MB-11 MB-14 MB-19"

case_in_set(){ local id=$1
  case "$SET" in
    quick)      case "$id" in MB-01|MB-03|MB-06|MB-10|MB-18) return 0;; *) return 1;; esac ;;
    ha)         case "$id" in MB-08|MB-10|MB-13) return 0;; *) return 1;; esac ;;
    doc)        case "$id" in MB-05|MB-11|MB-12|MB-15|MB-16|MB-17|MB-18) return 0;; *) return 1;; esac ;;
    neg)        case "$id" in MB-19) return 0;; *) return 1;; esac ;;
    regression|all) return 0 ;;
    *) return 1 ;;
  esac
}
case_in_only(){ local id=$1
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$id,"*) return 0;; *) return 1;; esac
}

case_file(){ local id=$1 low
  low=$(printf '%s' "$id" | tr 'A-Z' 'a-z' | tr '-' '_')
  ls "$SKILL"/cases/common/${low}_*.sh 2>/dev/null | head -1
}

SUITE="$OUTDIR/SUITE_${SET}_${RUN_ID}.out"
: >"$SUITE"
log(){ printf '%s\n' "$*" | tee -a "$SUITE"; }

log "=== 集合=$SET only=${ONLY:-<全部>} consensus=${CONSENSUS:-<env 默认>} ver=${VER:-<env 默认>} run_id=$RUN_ID ==="
total=0; pass=0; failn=0; skipped=0
for id in $ALL_CASES; do
  if ! case_in_set "$id" || ! case_in_only "$id"; then skipped=$((skipped+1)); continue; fi
  f=$(case_file "$id")
  [ -z "$f" ] && { log "!! 找不到用例文件: $id"; failn=$((failn+1)); continue; }
  total=$((total+1))
  args=()
  [ -n "$CONSENSUS" ] && args+=(--consensus "$CONSENSUS")
  [ -n "$VER" ] && args+=(--ver "$VER")
  log ""
  log "########## [$id] $(basename "$f") ##########"
  # 子进程输出不走 `| tee` 管道，改重定向到临时文件。
  #
  # ⚠️ 本环境（172.20.70.3）有一个**已知的 ssh/会话层问题**：经 run_all 调用用例时，
  #   run_all 看到的子进程有时会收到 SIGKILL（bash 报 `Killed`，rc=137），
  #   **但用例本身并没有死** —— 它脱离了父进程继续跑完（PPID=1 的孤儿），并正常写出
  #   `results/result_<CASE>_<RUNID>.txt` 与 `RESULT PASS/FAIL` 行。
  #   证据：19:04 那次 MB-01 报 rc=137，但 artifacts 显示它继续跑到 19:15:35 并 `RESULT PASS`；
  #         21:26 检查时仍有 PPID=1 的 mb_06 在跑（etime 4 分钟）。
  #   ⇒ 判定不能只看 rc：rc=137 时**等这个用例自己收尾**（轮询它的 result 文件），
  #     以用例自己写的 RESULT 为准；等不到才算真失败。
  caselog="$OUTDIR/.case_${id}_${RUN_ID}.tmp"
  case_result_file() { ls -t "$OUTDIR"/result_${id}_*.txt 2>/dev/null | head -1; }
  rm -f "$OUTDIR"/result_${id}_*.txt 2>/dev/null || true
  setsid bash "$f" ${args[@]+"${args[@]}"} >"$caselog" 2>&1 < /dev/null 9>&-
  rc=$?
  if [ "$rc" -eq 137 ]; then
    log "!! [$id] run_all 观察到 SIGKILL(rc=137)，但用例可能仍在后台跑；等它自己收尾（最多 1500s）"
    dl=$(( $(date +%s) + 1500 ))
    while (( $(date +%s) < dl )); do
      rf=$(case_result_file)
      [ -n "$rf" ] && break
      # 若连用例进程都不在了、也没有 result 文件 ⇒ 真的死了，不再等
      if ! ps -eo args | grep -q "[m]embuf_skill/cases/common/${f##*/}"; then
        sleep 5
        rf=$(case_result_file)
        break
      fi
      sleep 10
    done
    rf=$(case_result_file)
    if [ -n "$rf" ]; then
      log "!! [$id] 用例自身已收尾（result 文件：$(basename "$rf")），以用例结论为准"
      rc=0
    else
      log "!! [$id] 等不到用例自身的 result 文件 ⇒ 判定为环境导致的失败"
    fi
  fi
  cat "$caselog" | tee -a "$SUITE" >/dev/null
  cat "$caselog"
  rm -f "$caselog"
  # 从用例产物里取判定行
  # 注意：判定行是 "[时间戳] RESULT PASS ..."，不能锚定行首（首轮就因此把 PASS 判成 FAIL）
  r=$(grep -hoE 'RESULT (PASS|FAIL)' "$SUITE" | tail -1 | awk '{print $2}')
  if [ "$r" = "PASS" ]; then pass=$((pass+1)); else failn=$((failn+1)); log "!! [$id] 判为 FAIL（rc=$rc）"; fi
done

log ""
log "=== 汇总: 执行=$total PASS=$pass FAIL=$failn 跳过=$skipped ==="
log "结果表: $CSV"
log "套件输出: $SUITE"
[ "$failn" -eq 0 ] || exit 1
