#!/bin/bash
# ============================================================================
# 【纯桩 lib/cmp.sh】—— CR-14 离线干跑用；只实现 CR-14 用到的 cmp_* 接口
#   cmp_eff 读"运行期生效配置"（$STUB_STATE/runtime.properties）——**只有重启才会更新它**
#   cmp_set_hot 走假 CLI 的 `set configuration`（模式 ok 时只改配置层，不产生运行期效果）
# ============================================================================
COMMON_ERR_PAT='NullPointerException|OutOfMemoryError|Java heap space|GC overhead limit exceeded|IndexOutOfBoundsException|NumberFormatException'
CMP_ERR_PAT='Compaction[^|]*(failed|Failed)|Failed to (compaction|compact|merge)|CompactionException'
BENIGN_PAT='Not TTL rule set'

# 该节点上运行期**生效**值（只有"重启"会改 runtime.properties）
cmp_eff(){ local k=$2; awk -F= -v k="$k" '$1==k{print $2; exit}' "$STUB_STATE/runtime.properties"; }
cmp_eff_all(){ local k out=""; for k in last_cache_operation_on_load cache_last_values_for_load cache_last_values_memory_budget_in_byte enable_last_cache; do out="$out$k=$(cmp_eff "$1" "$k") "; done; echo "$out"; }
cmp_set_hot(){ sq "set configuration '$1'='$2';" 2>&1 | tr '\n' ' '; }
cmp_tpl_has(){ echo 1; }
cmp_all_sum(){ find "$STUB_NODES" -path "*/$1/*" -name '*.tsfile' 2>/dev/null | wc -l | tr -dc '0-9'; }
cmp_seq_sum(){ cmp_all_sum "$1"; }
cmp_unseq_cnt(){ echo 0; }
cmp_start_cnt_all(){ local h s=0 n; for h in "${DN[@]}"; do n=$(grep -hc 'Compaction task starts' "$STUB_NODES/$h/logs/log_datanode_all.log" 2>/dev/null); s=$(( s + ${n:-0} )); done; echo "${s:-0}"; }
cmp_finish_cnt_all(){ local h s=0 n; for h in "${DN[@]}"; do n=$(grep -hc 'Compaction task finishes successfully' "$STUB_NODES/$h/logs/log_datanode_all.log" 2>/dev/null); s=$(( s + ${n:-0} )); done; echo "${s:-0}"; }
cmp_compaction_off(){ log "  纯桩：已热关三类合并（无副作用）"; }
cmp_compaction_on(){ log "  纯桩：已热开合并（无副作用）"; }
cmp_log_files(){ echo "$STUB_STATE/logs_placeholder.log"; }
cmp_fingerprint(){ if [ "$1" = table ]; then norm_result "$(sqt "$2")"; else norm_result "$(sq "$2")"; fi; }
cmp_assert_same(){ if [ "$2" = "$3" ]; then pass "$1：完全一致"; else fail "$1：不一致"; fi; }
cmp_min_l0(){ echo 1; }
cmp_lay(){ echo "77:1/0/0/0 78:1/0/0/0 79:1/0/0/0 "; }
cmp_wait_close(){ echo 1; return 0; }
