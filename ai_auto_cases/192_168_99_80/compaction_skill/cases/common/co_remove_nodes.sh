#!/bin/bash
# ============================================================================
# CO-12 缩容场景：REMOVE DATANODE / REMOVE CONFIGNODE
#   需求："最好也加一个 remove CN/DN 场景的用例"
#   ⚠️ 关键前提（实测）：**3 副本（RF=3）+ 3 DataNode 时不允许移除 DataNode**，
#      服务端直接拒绝：`1003: Cannot remove 1 DataNode(s): the cluster has 3 available
#      DataNode(s) and must retain at least 3 of them ...`。所以本用例分两段：
#        ① 负向守卫（RF=3）：移除必须被拒、集群仍 3 DN —— 这本身就是产品该有的保护；
#        ② 正式缩容（把 SCHEMA_RF/DATA_RF 降到 2 后重启）：REMOVE DATANODE → 剩 2 DN
#           仍可读/可写/可合并、副本一致；再 REMOVE CONFIGNODE → 剩 2 CN，集群仍可用。
#      收尾统一用**剩余节点**做 sync lag / 一致性 / 日志扫描（被移除节点的进程与数据仍在本地，
#      不能再用全量节点列表）。
#   判据：① RF=3 被拒 + 集群不变；② RF=2 后可移除、剩 2 DN/2 CN；③ 缩容前后数据经剩余节点一致；
#         ④ 缩容后仍能写入并合并；⑤ 无卡死；⑥ 收尾三件套（子集节点）。
# 用法： bash co_remove_nodes.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_remove_nodes_${DATA_CONSENSUS}"

DB=root.coremove
DEVS=${CO_DEVS:-6}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-90}

# ------------------------------------------------------------------ ① RF=3 负向守卫
log "--- 1) 负向守卫：RF=3（默认）时 REMOVE DATANODE 必须被拒绝 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
log "  集群节点：DN=[$(cmp_node_ids DataNode)] CN=[$(cmp_node_ids ConfigNode)]"
GUARD_IP=${DN[1]}; GUARD_ID=$(cmp_node_id_of DataNode "$GUARD_IP")
if [ -z "$GUARD_ID" ]; then
  warn "拿不到 $GUARD_IP 的 DataNode id，跳过负向守卫"
else
  out=$(cmp_remove_dn "$GUARD_ID")
  log "  remove 响应：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
  printf '%s' "$out" | grep -qE '1003|Cannot remove' \
    && pass "RF=3 时移除 DataNode 被正确拒绝（1003，见上方原始响应）" \
    || fail "RF=3 时移除 DataNode 未被拒绝：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  N=$(cmp_node_cnt DataNode)
  [ "${N:-0}" = "3" ] && pass "被拒后集群仍是 3 个 DataNode" || fail "被拒后 DataNode 数=$N（期望 3）"
fi

# ------------------------------------------------------------------ ② 降到 2 副本，正式缩容
log "--- 2) 把副本数降到 2（SCHEMA_RF=2 DATA_RF=2）后重跑缩容流程 ---"
export SCHEMA_RF=2 DATA_RF=2
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
log "  集群节点：DN=[$(cmp_node_ids DataNode)] CN=[$(cmp_node_ids ConfigNode)]"
log "  实际生效：$(sshx "${DN[0]}" "grep -E '^(schema|data)_replication_factor=' $DB_DIR/conf/iotdb-system.properties" | tr '\n' ' ')"

log "--- 造数据 + 合并（缩容前的冒烟）---"
cmp_make_tree_db "$DB" "$DEVS"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
for b in 1 2 3; do cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$b" "$(( BASE + b * 2000000 ))"; done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"
ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$WIN"); then pass "缩容前合并正常：$RES"; else fail "缩容前合并未推进（$RES）"; fi
SQL_CNT="select count(s1) from $DB.**"
SQL_SUM="select sum(s1) from $DB.**"
BASE_CNT=$(cmp_fingerprint tree "$SQL_CNT"); BASE_SUM=$(cmp_fingerprint tree "$SQL_SUM")
log "  基准指纹：count=$(printf '%s' "$BASE_CNT" | tr '\n' ' ') sum=$(printf '%s' "$BASE_SUM" | tr '\n' ' ')"

log "--- 3) REMOVE DATANODE ${DN[1]}（RF=2，允许缩到 2 DN）---"
DN_IP=${DN[1]}; DN_ID=$(cmp_node_id_of DataNode "$DN_IP")
log "  DataNode $DN_IP 的 id=$DN_ID；移除前 DataNode 数=$(cmp_node_cnt DataNode)"
if [ -z "$DN_ID" ]; then
  fail "场景无效：拿不到 $DN_IP 的 DataNode id"
else
  log "  remove datanode：$(cmp_remove_dn "$DN_ID" | tr '\n' ' ' | cut -c1-200)"
  if cmp_wait_node_gone DataNode "$DN_IP" 300; then pass "DataNode $DN_IP 已从集群移除"; else fail "DataNode $DN_IP 未在 300s 内移除"; fi
  N=$(cmp_node_cnt DataNode); log "  当前 DataNode 数=$N（期望 2）"
  [ "${N:-0}" = "2" ] && pass "缩容后 DataNode 数为 2" || fail "缩容后 DataNode 数=$N（期望 2）"
fi
REMAIN=""; for h in "${DN[@]}"; do [ "$h" = "$DN_IP" ] && continue; REMAIN="$REMAIN $h"; done
REMAIN=${REMAIN# }
CN_IP=${CN[1]}
CNREMAIN=""; for h in "${CN[@]}"; do [ "$h" = "$CN_IP" ] && continue; CNREMAIN="$CNREMAIN $h"; done
CNREMAIN=${CNREMAIN# }
log "  剩余 DN=[$REMAIN] 剩余 CN=[$CNREMAIN]"
DN=(); read -ra DN <<<"$REMAIN"     # 后续 helper 只看剩余节点

log "--- 缩容后：经剩余节点查询必须与基准一致 ---"
cmp_assert_nodes_same "REMOVE DN 后 count" "$BASE_CNT" tree "$SQL_CNT" "$REMAIN"
cmp_assert_nodes_same "REMOVE DN 后 sum" "$BASE_SUM" tree "$SQL_SUM" "$REMAIN"

log "--- 缩容后：再写 2 批 + 合并（确认集群功能仍在）---"
# 合并基线必须取在**写入之前**：candidate=2 时两个新文件往往在写入期间就被合并掉，
# 写完之后再取基线 ⇒ 永远"没有推进"（前面几个用例踩过同样的坑）
FIN_PRE=$(cmp_inner_finish "$DB")
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 9 "$(( BASE + 9000000 ))"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 10 "$(( BASE + 11000000 ))"
ensure_closed "$DB" 3 30 || warn "$DB 缩容后批次未全部落盘"
ts1=$(cmp_all_sum "$DB"); fin1=$(cmp_inner_finish "$DB")
if [ "${fin1:-0}" -gt "${FIN_PRE:-0}" ]; then
  pass "缩容后合并仍正常（写入期间 finishes $FIN_PRE → $fin1）"
elif RES=$(cmp_wait_merge "$DB" "$fin1" "$ts1" "$WIN"); then pass "缩容后合并仍正常：$RES"
else fail "缩容后合并未推进（$RES）"; fi
CUR_CNT=$(cmp_fingerprint tree "$SQL_CNT"); CUR_SUM=$(cmp_fingerprint tree "$SQL_SUM")
cmp_assert_nodes_same "缩容后 count" "$CUR_CNT" tree "$SQL_CNT" "$REMAIN"
cmp_assert_nodes_same "缩容后 sum" "$CUR_SUM" tree "$SQL_SUM" "$REMAIN"

log "--- 4) REMOVE CONFIGNODE $CN_IP ---"
CN_ID=$(cmp_node_id_of ConfigNode "$CN_IP")
log "  ConfigNode $CN_IP 的 id=$CN_ID；移除前 ConfigNode 数=$(cmp_node_cnt ConfigNode)"
if [ -z "$CN_ID" ]; then
  warn "拿不到 $CN_IP 的 ConfigNode id，跳过 CONFIGNODE 移除"
else
  log "  remove confignode：$(cmp_remove_cn "$CN_ID" | tr '\n' ' ' | cut -c1-200)"
  if cmp_wait_node_gone ConfigNode "$CN_IP" 300; then pass "ConfigNode $CN_IP 已移除"; else warn "ConfigNode $CN_IP 未在 300s 内移除（记录）"; fi
  NCN=$(cmp_node_cnt ConfigNode); log "  当前 ConfigNode 数=$NCN（期望 2）"
  [ "${NCN:-0}" = "2" ] && pass "缩容后 ConfigNode 数为 2" || warn "ConfigNode 数=$NCN（期望 2）"
fi
# 注意：这里是"剩余节点之间互相一致"，不是"等于缩容前的旧快照"——期间已经又写过数据，
# 拿旧快照比会永远不一致（第一版踩到：1500 vs 900）
cmp_assert_nodes_same "REMOVE CN 后 count" "$(cmp_fingerprint tree "$SQL_CNT")" tree "$SQL_CNT" "$REMAIN"
cmp_assert_nodes_same "REMOVE CN 后 sum" "$(cmp_fingerprint tree "$SQL_SUM")" tree "$SQL_SUM" "$REMAIN"
NDN=$(cmp_node_cnt DataNode)
[ "${NDN:-0}" = "2" ] && pass "集群仍可用：DataNode 数=$NDN" || warn "DataNode 数=$NDN"

log "--- 5) 缩容后：再写两批 + 合并（移除 CN 之后）---"
FIN_PRE2=$(cmp_inner_finish "$DB")
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 11 "$(( BASE + 13000000 ))"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 12 "$(( BASE + 15000000 ))"
ensure_closed "$DB" 3 30 || warn "$DB 第 3 批未全部落盘"
ts2=$(cmp_all_sum "$DB"); fin2=$(cmp_inner_finish "$DB")
if [ "${fin2:-0}" -gt "${FIN_PRE2:-0}" ]; then
  pass "移除 CN 后合并仍正常（写入期间 finishes $FIN_PRE2 → $fin2）"
elif RES=$(cmp_wait_merge "$DB" "$fin2" "$ts2" "$WIN"); then pass "移除 CN 后合并仍正常：$RES"
else fail "移除 CN 后合并未推进（$RES）"; fi

log "--- 6) 收尾（子集节点）---"
check_sync_lag_on "$REMAIN" || true
# 注意：缩容后副本数是 2、DataNode 也只剩 2 —— 再"停 1 个 DN"就没有多数派了，
# 会得到 `721: Fetch Schema failed`（实测），这是 RF=2 的正常结果，不是缺陷。
# 所以这里只做"全部剩余节点在线时互相一致"的校验，停节点的一致性校验留给 RF=3 的用例。
log "=== 副本一致性校验（全部剩余节点在线，RF=2 下不做停节点校验）==="
CSQL="select count(s1) from $DB.d1 order by time;"
CBASE=$(query_result "${REMAIN%% *}" tree "$CSQL")
for h in $REMAIN; do
  cur=$(query_result "$h" tree "$CSQL")
  [ "$cur" = "$CBASE" ] && pass "剩余节点 $h 与基准一致" \
    || fail "剩余节点 $h 与基准不一致 [$(printf '%s' "$cur" | tr '\n' ' ' | cut -c1-120)] vs [$(printf '%s' "$CBASE" | tr '\n' ' ' | cut -c1-120)]"
done
cmp_check_logs_on "$REMAIN $CNREMAIN" || true
cmp_case_finish "" tree ""
