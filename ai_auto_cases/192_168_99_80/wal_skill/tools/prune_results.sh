#!/bin/bash
# ============================================================================
# prune_results.sh —— RC8 收尾清理（策略：**只保留结论 + 需要提单的证据，其余删掉**）
#
# 用户口径（2026-10-21）："运行完测试后，如果没必要保留某些日志，就删除；
#                         如果用例 fail 需要提单，就需要打包 CN/DN 日志"
#
# 保留：
#   1. results/test_result.csv / final_results.csv        （历史结果，几十 KB）
#   2. docs/MATRIX_*.md                                   （矩阵报告）
#   3. results/<case>_<runid>.out  —— **只保留本轮（RC8 第二轮/第三轮）**，其它轮次删
#   4. results/artifact_*         —— **只保留 KEEP 清单里那些"还要提单/还要研发口径"的**，其余删
#   5. 打包产物 evidence_<skill>_<date>.tgz（保留清单里的 artifact + 对应 .out）
#
# 用法：
#   bash prune_results.sh                 # dry-run，只打印将删/将留（默认）
#   bash prune_results.sh --apply         # 真删
#   bash prune_results.sh --apply --keep-artifacts   # 连保留清单也删（只留 tgz）
# ============================================================================
set -uo pipefail
ROOT=/data/iotdb/autotest
APPLY=0; KEEP_ALL=1
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --no-keep-artifacts) KEEP_ALL=0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done
say(){ printf '%s\n' "$*"; }
size_of(){ du -sb "$@" 2>/dev/null | awk '{s+=$1} END{printf "%.1fM", s/1048576}'; }
# 需要保留 artifact 的用例（= 还要提 PLM 单 or 还要研发给口径 or 结论还没定）
KEEP_PAT='co06|dt_tree|co_object_ttl|co_param_gate|co_level_search|co_fast_fake|wal_memtable_snapshot|wal_param_invalid|wal_object|wal_recovery_metadata|wal_compress|wal_dir_config|wal_disk_readonly|wal_recovery_dn_down|wal_metrics|cr_table_time_only|cr_load_lastcache'

TOTAL_FREE=0
for s in compaction_skill crud_skill wal_skill; do
  R=$ROOT/$s/results
  [ -d "$R" ] || continue
  say "===== $s ====="
  # ---------- 1) 非本轮（RC8 第二轮起 = 2026-10-20 12:00 之后）的 .out ----------
  old_out=$(find "$R" -maxdepth 1 -name '*.out' ! -newermt '2026-10-20 12:00' 2>/dev/null)
  n_old=$(printf '%s\n' "$old_out" | sed '/^$/d' | wc -l)
  say "  [旧轮次 .out] ${n_old} 个 / $(size_of $old_out 2>/dev/null || echo 0M)"
  # ---------- 2) artifact_* ：保留清单 vs 其余 ----------
  keep_list=""; drop_list=""
  for d in "$R"/artifact_*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    if printf '%s' "$b" | grep -qE "$KEEP_PAT"; then keep_list="$keep_list $d"; else drop_list="$drop_list $d"; fi
  done
  n_keep=$(printf '%s' "$keep_list" | wc -w); n_drop=$(printf '%s' "$drop_list" | wc -w)
  say "  [artifact 保留] ${n_keep} 个 / $(size_of $keep_list 2>/dev/null || echo 0M)  （提单/研发口径证据）"
  say "  [artifact 可删] ${n_drop} 个 / $(size_of $drop_list 2>/dev/null || echo 0M)"
  if [ "$APPLY" = 1 ]; then
    [ -n "$old_out" ] && printf '%s\n' "$old_out" | while read -r f; do [ -n "$f" ] && rm -f "$f"; done
    for d in $drop_list; do rm -rf "$d"; done
    if [ "$KEEP_ALL" = 0 ]; then
      # 先把保留清单打包，再删目录（打包失败就不删）
      TGZ=$R/evidence_${s}_$(date +%Y%m%d).tgz
      if [ -n "$keep_list" ]; then
        ( cd "$R" && tar -czf "$TGZ" $(for d in $keep_list; do basename "$d"; done) ) && \
        for d in $keep_list; do rm -rf "$d"; done
      fi
      say "  [已打包] $TGZ"
    fi
    say "  [完成] 清理后 $s/results = $(du -sh "$R" 2>/dev/null | cut -f1)"
  fi
done
[ "$APPLY" = 0 ] && say "" && say "（dry-run：加 --apply 才会真删）"
exit 0
