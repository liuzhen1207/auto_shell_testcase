#!/bin/bash
# ============================================================================
# MD-C01 元数据的一致性 / 持久化 / 跨模型隔离
#
# 这是"元数据"这个测试目标最核心的一条：
#   1) 一致：同一条元数据查询在三个 DataNode 上结果完全相同（含逐个停 DN 后仍一致）
#   2) 持久：重启集群后，所有 SHOW 类元数据的**排序行集合摘要**必须一字不差
#   3) 隔离：树模型命名空间（root.*）与表模型命名空间互不串味
#
# 元数据摘要：把若干条查询的结果拼成 "### 名字\n<排序行集合>" 再取 md5，
#   任何一行、任何一列的变化都会改变摘要 —— 比逐条断言更容易发现"悄悄少了一行"。
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

T="root.${MD_PREFIX}_c01"
B="${MD_PREFIX}_c01"
TPL="tpl_${MD_PREFIX}_c01"
md_case_init "md_meta_consistency"
md_cluster_prepare

SNAP_TREE=(
  "databases::SHOW DATABASES;"
  "timeseries::SHOW TIMESERIES $T.**;"
  "devices::SHOW DEVICES $T.**;"
  "views::SHOW VIEW;"
  "ttl::SHOW ALL TTL;"
  "templates::SHOW SCHEMA TEMPLATES;"
)
SNAP_TABLE=(
  "databases::SHOW DATABASES;"
  "tables::SHOW TABLES FROM $B;"
  "desc::DESC $B.t1;"
  "create::SHOW CREATE TABLE $B.t1;"
  "views::SHOW VIEWS FROM $B;"
)
digest_tree(){ md_snapshot tree  "${SNAP_TREE[@]}"  | md5sum | awk '{print $1}'; }
digest_table(){ md_snapshot table "${SNAP_TABLE[@]}" | md5sum | awk '{print $1}'; }

log "--- 清理历史对象 ---"
drop_templates "$TPL"
drop_tree_db "$T"
drop_table_dbs "$B"

# ---------------------------------------------------------------------------
log "=== 1) 造一整套元数据（树模型 + 表模型） ==="
assert_ok "树：建库"       "$(sq "CREATE DATABASE $T;")"
assert_ok "树：建时序"     "$(sq "CREATE TIMESERIES $T.d1.s1 INT32;")"
assert_ok "树：建时序2"    "$(sq "CREATE TIMESERIES $T.d1.s2 INT64 TAGS(k1=v1);")"
assert_ok "树：建时序3"    "$(sq "CREATE TIMESERIES $T.d2.s1 FLOAT;")"
assert_ok "树：建模板"     "$(sq "CREATE SCHEMA TEMPLATE $TPL (m1 INT32, m2 FLOAT);")"
assert_ok "树：建视图"     "$(sq "CREATE VIEW $T.v1 AS SELECT s1 FROM $T.d1;")"
assert_ok "树：设 TTL"     "$(sq "SET TTL TO $T.d2 3600000;")"
assert_ok "表：建库"       "$(sqt "CREATE DATABASE $B;")"
assert_ok "表：建表 t1"    "$(sqt "CREATE TABLE $B.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "表：建表 t2"    "$(sqt "CREATE TABLE $B.t2 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD, m2 FLOAT FIELD);")"
assert_ok "表：建视图"     "$(sqt "CREATE VIEW $B.v1 (m1 INT32 FIELD) AS root.\"$B\".**;")"

tree_before=$(md_snapshot tree  "${SNAP_TREE[@]}")
table_before=$(md_snapshot table "${SNAP_TABLE[@]}")
d_tree_before=$(printf '%s' "$tree_before"  | md5sum | awk '{print $1}')
d_table_before=$(printf '%s' "$table_before" | md5sum | awk '{print $1}')
log "  重启前摘要：tree=$d_tree_before table=$d_table_before"

log "=== 2) 跨模型命名空间隔离 ==="
tn=$(md_names "$(sq 'SHOW DATABASES;')")
bn=$(md_names "$(sqt 'SHOW DATABASES;')")
assert_set_has   "树模型 SHOW DATABASES 含 root.$B" "$tn" "root.$B"
assert_set_lacks "树模型 SHOW DATABASES 不含表模型库名 $B" "$tn" "$B"
assert_set_has   "表模型 SHOW DATABASES 含 $B" "$bn" "$B"
assert_set_lacks "表模型 SHOW DATABASES 不含 root.$B" "$bn" "root.$B"
assert_set_lacks "表模型 SHOW DATABASES 不含 root.__system" "$bn" "root.__system"

log "=== 3) 副本一致性（元数据查询） ==="
consistency_check "SHOW TIMESERIES $T.**;" tree

log "=== 4) 重启集群（保留数据） ==="
cluster_stop
cluster_start

log "=== 5) 重启后摘要必须完全一致 ==="
tree_after=$(md_snapshot tree  "${SNAP_TREE[@]}")
table_after=$(md_snapshot table "${SNAP_TABLE[@]}")
d_tree_after=$(printf '%s' "$tree_after"  | md5sum | awk '{print $1}')
d_table_after=$(printf '%s' "$table_after" | md5sum | awk '{print $1}')
log "  重启后摘要：tree=$d_tree_after table=$d_table_after"
assert_eq "树模型元数据摘要重启后不变" "$d_tree_after" "$d_tree_before"
assert_eq "表模型元数据摘要重启后不变" "$d_table_after" "$d_table_before"
if [ "$tree_after" != "$tree_before" ]; then
  log "  树模型快照 diff："
  diff <(printf '%s\n' "$tree_before") <(printf '%s\n' "$tree_after") | head -40 >>"$OUT"
fi
if [ "$table_after" != "$table_before" ]; then
  log "  表模型快照 diff："
  diff <(printf '%s\n' "$table_before") <(printf '%s\n' "$table_after") | head -40 >>"$OUT"
fi

log "=== 6) 重启后逐项复核（摘要之外的可读断言） ==="
assert_ok "重启后集群仍 6 节点 Running" "$(sq 'SHOW CLUSTER;')"
assert_eq "重启后 SHOW CLUSTER 节点数" "$(md_count "$(md_rows "$(sq 'SHOW CLUSTER;')")")" "$(( ${#CN[@]} + ${#DN[@]} ))"
assert_set_has "重启后时序 d1.s1 仍在" "$(md_names "$(sq "SHOW TIMESERIES $T.**;")")" "$T.d1.s1"
assert_set_has "重启后视图 v1 仍在"    "$(md_names "$(sq 'SHOW VIEW;')")" "$T.v1"
assert_set_has "重启后模板仍在"        "$(md_names "$(sq 'SHOW SCHEMA TEMPLATES;')")" "$TPL"
assert_set_has "重启后表 t1 仍在"      "$(md_names "$(sqt "SHOW TABLES FROM $B;")")" "t1"

log "--- 清理 ---"
q_table "DROP VIEW IF EXISTS $B.v1"
drop_table_dbs "$B"
q_tree "DROP VIEW $T.v1"
drop_templates "$TPL"
drop_tree_db "$T"

# 一致性查询用 SHOW DATABASES（稳定）；SHOW CLUSTER 会随节点在线状态变化，不能用来比对副本
md_case_finish tree 'SHOW DATABASES;'
