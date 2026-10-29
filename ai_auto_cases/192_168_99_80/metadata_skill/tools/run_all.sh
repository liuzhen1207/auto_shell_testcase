#!/bin/bash
# ============================================================================
# 元数据 DDL 用例批量运行器
#
#   bash tools/run_all.sh [--set quick|tree|table|common|scale|all] [--consensus IoTConsensus|IoTConsensusV2]
#                        [--no-prepare] [--keep-data] [--only <用例号,用例号>]
#
# 设计：
#   * 默认先把集群准备一次（停 -> 清 -> 写配置 -> 启动），随后所有用例
#     以 SKIP_LIFECYCLE=1 复用同一个集群 —— 元数据用例大多不需要重启，
#     一次准备能省下大量时间。
#   * cases.tsv 的 lifecycle 列为 fresh 的用例要独占集群（自己会停清写启），
#     运行器会为它重新准备一次集群。
#   * 每条用例的 PASS/FAIL 由自己的 fail_flag 决定；汇总写 SUITE_SUMMARY。
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"

SET=quick
ONLY=""
NO_PREPARE=0
CASE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --set)         SET="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --no-prepare)  NO_PREPARE=1; shift ;;
    --keep-data)   CASE_ARGS+=(--keep-data); shift ;;
    --consensus)   CASE_ARGS+=(--consensus "$2"); shift 2 ;;
    --env)         CASE_ARGS+=(--env "$2"); shift 2 ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done

md_load_env
if [ "${#CASE_ARGS[@]}" -gt 0 ]; then md_parse_args "${CASE_ARGS[@]}"; fi
# 套件模式：用例收尾不关集群，下一条直接复用（否则每条都要停/清/启 ≈5 分钟）
export MD_NO_STOP_AFTER=1

TSV="$MD_SKILL_DIR/cases/cases.tsv"
[ -f "$TSV" ] || { echo "缺少 $TSV"; exit 2; }
# 先把用例清单读进数组：runner 的 stdin 会被子进程里的 CLI 抢着读
# （CLI 会从 stdin 读语句），直接 `while read ... done < $TSV` 会被吃掉后面的用例。
mapfile -t CASE_LINES <"$TSV"

select_case(){
  local id=$1 set=$2
  [ -n "$ONLY" ] && { case ",$ONLY," in *",$id,"*) return 0;; *) return 1;; esac; }
  case "$SET" in
    all)  return 0 ;;
    "$set") return 0 ;;
    *) return 1 ;;
  esac
}

SUITE_OUT="$MD_SKILL_DIR/results/SUITE_${SET}_$(date +%Y%m%d_%H%M%S).out"
mkdir -p "$MD_SKILL_DIR/results"
: >"$SUITE_OUT"
say(){ printf '%s\n' "$*" | tee -a "$SUITE_OUT"; }

prepared=0
prepare_cluster(){
  say "########## 准备集群（$V_TESTDB / $CONSENSUS_CLASS）##########"
  if bash "$MD_SKILL_DIR/tools/cluster_prepare.sh" --consensus "$DATA_CONSENSUS" $([ "${KEEP_DATA:-0}" = "1" ] && echo --keep-data) </dev/null >>"$SUITE_OUT" 2>&1; then
    prepared=1; return 0
  fi
  say "!! 集群准备失败，中止"; return 1
}

say "=== 元数据 DDL 用例集：set=$SET 版本=$V_TESTDB 协议=${CONSENSUS_CLASS##*.} 开始 $(date '+%F %T') ==="
say "用例清单（$TSV）："
say "$(awk -F'\t' 'NR>1 && $1!="" && $1 !~ /^#/ {printf "  %-8s %-7s %-6s %s\n",$1,$2,$3,$6}' "$TSV")"

n_all=0 n_pass=0 n_fail=0 n_skip=0
FAILED_LIST=""
for _line in "${CASE_LINES[@]}"; do
  IFS=$'\t' read -r id cset dialect script lifecycle title <<<"$_line"
  case "$id" in ''|'#'*) continue ;; esac
  n_all=$((n_all+1))
  if ! select_case "$id" "$cset"; then n_skip=$((n_skip+1)); continue; fi

  if [ "$lifecycle" = fresh ]; then
    prepare_cluster || exit 1
    run_args=()
  else
    if [ "$prepared" -eq 0 ] && [ "$NO_PREPARE" -eq 0 ]; then
      prepare_cluster || exit 1
    fi
    run_args=(--skip-lifecycle)
  fi
  if [ "${#CASE_ARGS[@]}" -gt 0 ]; then run_args+=("${CASE_ARGS[@]}"); fi

  say ""
  say "########## [$id] $title —— $(date '+%F %T') ##########"
  # 注意：必须 </dev/null —— 否则用例里的 CLI 会继承 runner 的 stdin（= cases.tsv）
  # 并把它读空，导致后面的用例被"吃掉"（踩过：只跑了第一条就结束）。
  bash "$MD_SKILL_DIR/cases/$script" "${run_args[@]}" </dev/null >"$MD_SKILL_DIR/results/${id}_run.out" 2>&1
  rc=$?
  line=$(grep -hE 'RESULT (PASS|FAIL)' "$MD_SKILL_DIR/results/${id}_run.out" | tail -1)
  res=$(printf '%s' "$line" | sed -nE 's/.*RESULT ([A-Z]+).*/\1/p')
  el=$(printf '%s' "$line" | sed -nE 's/.*elapsed=([0-9]+)s.*/\1/p')
  say "  -> rc=$rc ${line:-<无 RESULT 行>}"
  if [ "$res" = PASS ]; then n_pass=$((n_pass+1)); else n_fail=$((n_fail+1)); FAILED_LIST="$FAILED_LIST $id"; fi
done

say ""
say "=== 汇总 $(date '+%F %T') ==="
say "选中共 $((n_all-n_skip)) 条：PASS=$n_pass FAIL=$n_fail（跳过未选中 $n_skip 条）"
[ -n "$FAILED_LIST" ] && say "失败用例：$FAILED_LIST"
say "明细 CSV：$MD_SKILL_DIR/results/test_result.csv"
say "套件输出：$SUITE_OUT"
# 套件结束：停集群，把环境交还（下一轮 run_all 会重新准备）
if [ "$NO_PREPARE" -eq 0 ]; then
  say "--- 套件结束，停止集群 ---"
  ( export DATA_CONSENSUS MD_NO_STOP_AFTER=0 KEEP_DATA=0
    . "$MD_SKILL_DIR/lib/common.sh"
    md_load_env
    OUT="$SUITE_OUT"; CASE=suite_stop; RUN_ID=suite; fail_flag=0; v_warnMessage=""
    cluster_stop ) >>"$SUITE_OUT" 2>&1 || say "（停集群失败，忽略）"
fi
[ "$n_fail" -eq 0 ]
