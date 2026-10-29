#!/bin/bash
# ============================================================================
# probe_ratio_isolate.sh —— 隔离实验：expired_data_ratio 到底在什么条件下生效
#
#   现象（ttl_param_effect 用例 C1）：expired_data_ratio=0.99 + max_expired_time=1h +
#   TTL=120s 时，只过期的设备占 1/3 的文件在过期后第一次 TTL 检查就被 settle 了。
#
#   三相对照：
#     A) max_expired_time=1h        + ratio=0.99  → 期望（按文档）不清理；实测若清理 → 强制规则短路了比例门控
#     B) max_expired_time=Long.MAX + ratio=0.99  → 关闭强制规则，只由比例决定 → 期望不清理
#     C) max_expired_time=Long.MAX + ratio=0.0   → 期望清理（证明链路本身正常）
#
#   判读：A 清理 且 B 不清理 ⇒ expired_data_ratio 被"过期即算过期太久"短路（缺陷）；
#         C 正常 ⇒ 清理链路本身没问题。
# ============================================================================
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$SKILL_DIR/lib/common.sh"
ttl_load_env
ttl_case_init probe_ratio_isolate

TTL_MS="${TTL_MS:-120000}"
CHECK_INTERVAL_MS="${CHECK_INTERVAL_MS:-15000}"
WAIT_AFTER="${WAIT_AFTER:-$(( TTL_MS / 1000 + 70 ))}"
SUMMARY="$ART/probe_summary.txt"
: >"$SUMMARY"

settle_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(settle_task_for_db "$h" "$db"))); done; echo "$s"; }
sel_sum(){    local db=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $(ttl_sel_for_db   "$h" "$db"))); done; echo "$s"; }
# 该库在各节点上的（已落盘）TsFile 数
tsfile_per_node(){ local db=$1 h n; local -a r=(); for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*${db#root.}*' -name '*.tsfile' 2>/dev/null | wc -l" | tr -dc '0-9'); r+=("$h:${n:-0}"); done
  echo "${r[*]}"; }
# 确保 3 个副本都有落盘文件（否则该节点不会参与 settle 选择，结论会被削弱）
ensure_flushed(){ local db=$1 i n h miss; for i in 1 2 3; do sq "flush;" >/dev/null; sleep 5
    miss=0; for h in "${DN[@]}"; do n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*${db#root.}*' -name '*.tsfile' 2>/dev/null | wc -l" | tr -dc '0-9'); [ "${n:-0}" -gt 0 ] || miss=$((miss+1)); done
    log "  flush 第 $i 次：$miss 个节点尚无落盘 TsFile（$(tsfile_per_node "$db")）"
    [ "$miss" -eq 0 ] && return 0; done; return 1; }

run_phase(){
  local name=$1 ratio=$2 maxexp=$3 expect=$4
  local db="root.probe_${name}" h t base done_settle
  log "=================================================================="
  log "Phase $name: expired_data_ratio=$ratio  max_expired_time=$maxexp  (期望: $expect)"
  cluster_stop
  MAX_EXPIRED_TIME_MS="$maxexp" EXPIRED_DATA_RATIO="$ratio" \
  TTL_CHECK_INTERVAL_MS="$CHECK_INTERVAL_MS" cluster_write_conf
  cluster_start

  # 逐节点确认"生效配置"（show configuration 读的是各 DN 实际加载的值）
  for h in "${DN[@]}"; do
    local sc
    sc=$(sq_node "$h" 'show configuration;' 2>&1 | grep -E 'expired_data_ratio|max_expired_time' | tr '\n' ' ')
    log "  生效配置($h): ${sc:-<show configuration 无输出/不支持>}"
  done

  sq "create database $db;" >/dev/null
  for h in d1 d2 d3; do sq "create timeseries $db.$h.s1 with datatype=int64;" >/dev/null; done
  sq "set ttl to $db.d1 $TTL_MS;" >/dev/null            # 只有 d1 有过期规则 → 过期设备占比 ≤ 1/3
  t=$(now_ms)
  for h in d1 d2 d3; do sq "insert into $db.$h(time,s1) values($t, 1);" >/dev/null; done
  sleep 3
  ensure_flushed "$db" || warn "$db 有节点未落盘 TsFile，该节点可能不参与 settle 选择"
  log "  各节点落盘 TsFile 数: $(tsfile_per_node "$db")"

  base=$(settle_sum "$db")
  log "  写入 T=$t（TTL=$((TTL_MS/1000))s），基线 settle=$base；等待 ${WAIT_AFTER}s"
  sleep "$WAIT_AFTER"
  done_settle=$(settle_sum "$db")
  log "  [$name] 真实 settle 任务: $base -> $done_settle（候选选中 $(sel_sum "$db") 行）"
  for h in "${DN[@]}"; do
    log "  [$name] $h [TTL] 记录: $(ttl_last_line_for_db "$h" "$db" | tr '\n' ' ' | cut -c1-200)"
  done
  printf 'phase=%s ratio=%s max_expired_time=%s settle_increment=%s expect=%s\n' \
    "$name" "$ratio" "$maxexp" "$((done_settle - base))" "$expect" >>"$SUMMARY"

  # 断言（本探针用于定位，不追求 fail_flag）
  case "$name" in
    A) [ $((done_settle - base)) -gt 0 ] && log "  >>> A: 被清理了（比例 0.99 未起作用）" || log "  >>> A: 未清理（与用例 C1 观测不一致）" ;;
    B) [ $((done_settle - base)) -eq 0 ] && log "  >>> B: 未清理（关闭强制规则后比例门控生效 = 文档语义）" || log "  >>> B: 被清理了（比例门控在 M=INF 时也未生效！）" ;;
    C) [ $((done_settle - base)) -gt 0 ] && log "  >>> C: 被清理（清理链路正常）" || log "  >>> C: 未清理（异常，需排查）" ;;
  esac
}

log "隔离实验参数：TTL=${TTL_MS}ms  ttl_check_interval=${CHECK_INTERVAL_MS}ms  等待=${WAIT_AFTER}s  build=$BUILD_TAG"
run_phase a 0.99 3600000            "按文档：1h 内即使过期比例 <0.99 也不清理"
run_phase b 0.99 9223372036854775807 "关闭强制规则：比例 0.99 未达到 → 不清理"
run_phase c 0.0  9223372036854775807 "关闭强制规则：比例 0.0 → 应清理"

log "================ 汇总（$SUMMARY）================"
cat "$SUMMARY" >>"$OUT"
cat "$SUMMARY"
log "RESULT probe 完成（本脚本只做定位，fail_flag=$fail_flag）；日志：$OUT"
cluster_stop
