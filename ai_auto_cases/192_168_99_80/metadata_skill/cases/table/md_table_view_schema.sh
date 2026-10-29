#!/bin/bash
# ============================================================================
# MD-B02 表模型 VIEW + information_schema 元数据一致性
#
# 覆盖：
#   CREATE VIEW <t>(列定义) AS <树路径>（表视图；源必须以 ** 结尾）
#   CREATE VIEW <lv> AS SELECT …（逻辑视图）
#   SHOW VIEWS / SHOW TREE VIEWS / SHOW CREATE VIEW / ALTER VIEW RENAME TO / DROP VIEW
#   information_schema.databases / tables / columns / views / functions / services
#   与 SHOW 系列**交叉校验**（同一对象在 information_schema 与 SHOW 里必须一致）
#   失败路径：视图源路径不以 ** 结尾（701）、information_schema.indexes 不存在（550）、
#             index DDL 未支持（701）、SHOW DEVICES/COUNT DEVICES 需 FROM 表（700）
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

TDB="${MD_PREFIX}_b02"
TREE_DB="root.${MD_PREFIX}_b02"
md_case_init "md_table_view_schema"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_table_dbs "$TDB"
drop_tree_db "$TREE_DB"
assert_ok "表模型建库" "$(sqt "CREATE DATABASE $TDB;")"
assert_ok "表模型建表" "$(sqt "CREATE TABLE $TDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "表模型写入一行" "$(sqt "INSERT INTO $TDB.t1 (time, dev, m1) VALUES (1700000000000, 'd1', 1);")"
# 表视图的源路径要求以 ** 结尾
assert_ok "树模型建库（供表视图引用）" "$(sq "CREATE DATABASE $TREE_DB;")"
assert_ok "树模型建时序" "$(sq "CREATE TIMESERIES $TREE_DB.d1.s1 INT32;")"

# ---------------------------------------------------------------------------
log "=== 1) 建表视图与逻辑视图 ==="
assert_ok "CREATE VIEW (表视图，源以 ** 结尾)" \
  "$(sqt "CREATE VIEW $TDB.v1 (m1 INT32 FIELD) AS root.\"$TDB\".**;")"
assert_ok "CREATE VIEW (逻辑视图 AS SELECT)" \
  "$(sqt "CREATE VIEW $TDB.lv1 AS SELECT m1 FROM $TDB.t1;")"

log "=== 2) SHOW VIEWS / SHOW CREATE VIEW / DROP VIEW ==="
vs=$(sqt "SHOW VIEWS FROM $TDB;")
vnames=$(md_names "$vs")
assert_set_has "SHOW VIEWS 含 v1"  "$vnames" "v1"
assert_set_has "SHOW VIEWS 含 lv1" "$vnames" "lv1"
assert_ok "SHOW TREE VIEWS" "$(sqt "SHOW TREE VIEWS FROM $TDB;")"
scv=$(sqt "SHOW CREATE VIEW $TDB.v1;")
assert_contains "SHOW CREATE VIEW 输出 CREATE VIEW" "$scv" 'CREATE VIEW'
assert_contains "SHOW CREATE VIEW 含列定义 m1" "$scv" 'm1'
# 表模型的视图改名是**支持**的（树模型 ALTER VIEW RENAME 报 701，两者不同）
assert_ok "ALTER VIEW RENAME TO（表模型支持）" "$(sqt "ALTER VIEW $TDB.v1 RENAME TO v1r;")"
assert_set_has   "SHOW VIEWS 含改名后的 v1r" "$(md_names "$(sqt "SHOW VIEWS FROM $TDB;")")" "v1r"
assert_set_lacks "SHOW VIEWS 不再含 v1"      "$(md_names "$(sqt "SHOW VIEWS FROM $TDB;")")" "v1"
assert_ok "DROP VIEW lv1（IF EXISTS 形式）" "$(sqt "DROP VIEW IF EXISTS $TDB.lv1;")"
assert_set_is "SHOW VIEWS 只剩 v1r" "$(md_names "$(sqt "SHOW VIEWS FROM $TDB;")")" "v1r"
assert_error "重复 DROP VIEW 550" "$(sqt "DROP VIEW $TDB.lv1;")" '550'

log "=== 3) information_schema 与 SHOW 交叉校验 ==="
ist=$(sqt "SELECT * FROM information_schema.tables;")
assert_contains "information_schema.tables 含本库" "$ist" "$TDB"
assert_contains "information_schema.tables 含表 t1" "$ist" 't1'
isc=$(sqt "SELECT * FROM information_schema.columns;")
assert_contains "information_schema.columns 含列 m1" "$isc" 'm1'
assert_contains "information_schema.columns 含列 dev" "$isc" 'dev'
isv=$(sqt "SELECT * FROM information_schema.views;")
assert_contains "information_schema.views 含 v1" "$isv" 'v1'
isd=$(sqt "SELECT * FROM information_schema.databases;")
assert_contains "information_schema.databases 含本库" "$isd" "$TDB"
assert_ok "information_schema.functions" "$(sqt "SELECT * FROM information_schema.functions;")"
assert_ok "information_schema.services" "$(sqt "SELECT * FROM information_schema.services;")"
assert_error "information_schema.indexes 不存在 550" \
  "$(sqt "SELECT * FROM information_schema.indexes;")" '550'

log "=== 4) 表模型的 index / devices 能力边界 ==="
assert_error "CREATE INDEX 未支持 701" "$(sqt "CREATE INDEX idx_b02 ON $TDB.t1 m1;")" '701'
assert_error "DROP INDEX 未支持 701"   "$(sqt "DROP INDEX idx_b02 ON $TDB.t1;")" '701'
assert_error "SHOW INDEXES 未支持 701" "$(sqt "SHOW INDEXES FROM $TDB.t1;")" '701'
assert_ok "SHOW DEVICES FROM <表>"     "$(sqt "SHOW DEVICES FROM $TDB.t1;")"
assert_ok "COUNT DEVICES FROM <表>"    "$(sqt "COUNT DEVICES FROM $TDB.t1;")"
assert_error "SHOW DEVICES FROM <库>（应为表名）701" "$(sqt "SHOW DEVICES FROM $TDB;")" '701'

log "=== 5) AINode 相关语句在无 AINode 时的行为 ==="
assert_error "SHOW MODELS（无 AINode）1011" "$(sqt 'SHOW MODELS;')" '1011'

log "--- 清理 ---"
q_table "DROP VIEW IF EXISTS $TDB.v1r"
q_table "DROP VIEW IF EXISTS $TDB.v1"
drop_table_dbs "$TDB"
drop_tree_db "$TREE_DB"

md_case_finish table 'SHOW DATABASES;'
