#!/bin/bash
# ============================================================================
# MD-B01 表模型 DATABASE / TABLE / COLUMN 元数据闭环
#
# 覆盖：
#   CREATE DATABASE [IF NOT EXISTS] / SHOW DATABASES [DETAILS] / SHOW CREATE DATABASE / COUNT DATABASES
#   ALTER DATABASE [IF EXISTS] SET PROPERTIES / DROP DATABASE [IF EXISTS]
#   USE <db>（会话内生效，SHOW CURRENT_DATABASE 跟随）
#   CREATE TABLE [IF NOT EXISTS] (…) [WITH (ttl=…, need_last_cache=…)]
#   SHOW TABLES [DETAILS] [FROM db] / DESC|DESCRIBE [DETAILS] / SHOW CREATE TABLE
#   ALTER TABLE ADD COLUMN [IF NOT EXISTS] / DROP COLUMN [IF EXISTS] / ALTER COLUMN SET DATA TYPE
#   ALTER TABLE SET PROPERTIES ttl=<ms>|'INF' / COMMENT ON TABLE|COLUMN
#   失败路径：重名库 501 / 重名表 551 / 删不存在的库 500 / 删不存在的表 550 /
#             会话未指定库时 SHOW TABLES 701 / RENAME TABLE、RENAME COLUMN 不支持 701 /
#             ttl='3600000'（带引号数字）被拒 701 / 列属性 ATTRIBUTES 不支持 700
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

TDB="${MD_PREFIX}_b01"
md_case_init "md_table_ddl"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_table_dbs "$TDB"

# ---------------------------------------------------------------------------
log "=== 1) 库级 DDL ==="
assert_ok "CREATE DATABASE" "$(sqt "CREATE DATABASE $TDB;")"
assert_ok "CREATE DATABASE IF NOT EXISTS（表模型支持）" "$(sqt "CREATE DATABASE IF NOT EXISTS $TDB;")"
assert_error "重复建库 501" "$(sqt "CREATE DATABASE $TDB;")" '501'

tdbs=$(sqt 'SHOW DATABASES;')
assert_set_has "SHOW DATABASES 含 $TDB" "$(md_names "$tdbs")" "$TDB"
assert_eq "COUNT DATABASES == SHOW DATABASES 行数" \
  "$(scalar "$(sqt 'COUNT DATABASES;')")" "$(md_count "$(md_rows "$tdbs")")"
cdb=$(sqt "SHOW CREATE DATABASE $TDB;")
assert_contains "SHOW CREATE DATABASE 输出建库语句" "$cdb" "CREATE DATABASE \"$TDB\""
assert_ok "ALTER DATABASE SET PROPERTIES" "$(sqt "ALTER DATABASE $TDB SET PROPERTIES ttl=3600000;")"
assert_contains "SHOW CREATE DATABASE 反映新 ttl" "$(sqt "SHOW CREATE DATABASE $TDB;")" 'ttl'

log "=== 2) USE 与 SHOW CURRENT_DATABASE ==="
sess=$(sql_on "$QDN" table "USE $TDB;;SHOW CURRENT_DATABASE;")
assert_contains "USE 后 SHOW CURRENT_DATABASE 为 $TDB" "$sess" "$TDB"

log "=== 3) 建表三种写法 ==="
assert_ok "CREATE TABLE 基础" "$(sqt "CREATE TABLE $TDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "CREATE TABLE IF NOT EXISTS" "$(sqt "CREATE TABLE IF NOT EXISTS $TDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "CREATE TABLE WITH (ttl=…, need_last_cache=…)" \
  "$(sqt "CREATE TABLE $TDB.t2 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD) WITH (ttl=3600000, need_last_cache=false);")"
assert_error "重复建表 551" "$(sqt "CREATE TABLE $TDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")" '551'

log "=== 4) SHOW TABLES / DESC / SHOW CREATE TABLE ==="
tabs=$(sqt "SHOW TABLES FROM $TDB;")
assert_set_is "SHOW TABLES 名字集合" "$(md_names "$tabs")" "t1" "t2"
assert_ok "SHOW TABLES DETAILS" "$(sqt "SHOW TABLES DETAILS FROM $TDB;")"
desc=$(sqt "DESC $TDB.t1;")
assert_eq "DESC 列出 3 列" "$(md_count "$(md_rows "$desc")")" "3"
assert_set_is "DESC 列名集合" "$(printf '%s\n' "$desc" | md_col 1 | sort -u)" "time" "dev" "m1"
assert_eq "time 列是 TIME" "$(printf '%s\n' "$desc" | md_col 2 | head -1)" "TIMESTAMP"
assert_ok "DESC … DETAILS" "$(sqt "DESC $TDB.t1 DETAILS;")"
sc=$(sqt "SHOW CREATE TABLE $TDB.t1;")
assert_contains "SHOW CREATE TABLE 含建表列定义" "$sc" 'CREATE TABLE'
assert_contains "SHOW CREATE TABLE 含 ttl" "$sc" 'ttl'
assert_contains "SHOW CREATE TABLE 含 need_last_cache" "$sc" 'need_last_cache'

log "=== 5) 列级 DDL 后 DESC 必须变 ==="
assert_ok "ADD COLUMN m2" "$(sqt "ALTER TABLE $TDB.t1 ADD COLUMN m2 FLOAT FIELD;")"
assert_set_has "DESC 出现 m2" "$(printf '%s\n' "$(sqt "DESC $TDB.t1;")" | md_col 1 | sort -u)" "m2"
assert_ok "ADD COLUMN IF NOT EXISTS 已存在列" "$(sqt "ALTER TABLE $TDB.t1 ADD COLUMN IF NOT EXISTS m2 FLOAT FIELD;")"
assert_eq "IF NOT EXISTS 不产生重复列" "$(printf '%s\n' "$(sqt "DESC $TDB.t1;")" | md_col 1 | sort -u | grep -cx 'm2')" "1"
assert_ok "ALTER COLUMN SET DATA TYPE INT32→INT64" "$(sqt "ALTER TABLE $TDB.t1 ALTER COLUMN m1 SET DATA TYPE INT64;")"
assert_eq "DESC 中 m1 变为 INT64" "$(printf '%s\n' "$(sqt "DESC $TDB.t1;")" | awk -F'|' '$2 ~ /m1/ {gsub(/ /,"",$3); print $3}')" "INT64"
assert_ok "DROP COLUMN m2" "$(sqt "ALTER TABLE $TDB.t1 DROP COLUMN m2;")"
assert_set_lacks "DESC 不再有 m2" "$(printf '%s\n' "$(sqt "DESC $TDB.t1;")" | md_col 1 | sort -u)" "m2"
assert_ok "DROP COLUMN IF EXISTS 不存在的列" "$(sqt "ALTER TABLE $TDB.t1 DROP COLUMN IF EXISTS m9;")"

log "=== 6) 表属性与注释 ==="
assert_ok "SET PROPERTIES ttl=7200000（不带引号）" "$(sqt "ALTER TABLE $TDB.t1 SET PROPERTIES ttl=7200000;")"
assert_contains "SHOW CREATE TABLE 反映新 ttl" "$(sqt "SHOW CREATE TABLE $TDB.t1;")" 'ttl=7200000'
assert_ok "SET PROPERTIES ttl='INF'" "$(sqt "ALTER TABLE $TDB.t1 SET PROPERTIES ttl='INF';")"
assert_ok "COMMENT ON TABLE" "$(sqt "COMMENT ON TABLE $TDB.t1 IS 'hello';")"
assert_ok "COMMENT ON COLUMN" "$(sqt "COMMENT ON COLUMN $TDB.t1.m1 IS 'col comment';")"

log "=== 7) 失败路径 ==="
assert_error "RENAME TABLE 不支持 701"    "$(sqt "ALTER TABLE $TDB.t1 RENAME TO t1r;")" '701'
assert_error "RENAME COLUMN 不支持 701"   "$(sqt "ALTER TABLE $TDB.t1 RENAME COLUMN m1 TO mm1;")" '701'
assert_error "ttl 用带引号数字被拒 701"    "$(sqt "ALTER TABLE $TDB.t1 SET PROPERTIES ttl='3600000';")" '701'
assert_error "列属性 ATTRIBUTES 不支持 700" \
  "$(sqt "CREATE TABLE $TDB.t9 (time TIMESTAMP TIME, dev STRING TAG ATTRIBUTES(k='v'), m1 INT32 FIELD);")" '700'
assert_error "会话未指定库时 SHOW TABLES 701" "$(sqt 'SHOW TABLES;')" '701'
assert_error "删不存在的表 550"           "$(sqt "DROP TABLE $TDB.t9;")" '550'
assert_error "删不存在的库 500"           "$(sqt "DROP DATABASE ${MD_PREFIX}_nosuch_b01;")" '500'
assert_ok "DROP TABLE IF EXISTS 不存在的表" "$(sqt "DROP TABLE IF EXISTS $TDB.t9;")"

log "=== 8) 删表/删库后元数据干净 ==="
assert_ok "DROP TABLE t2" "$(sqt "DROP TABLE $TDB.t2;")"
assert_set_is "SHOW TABLES 只剩 t1" "$(md_names "$(sqt "SHOW TABLES FROM $TDB;")")" "t1"
assert_ok "DROP TABLE IF EXISTS t2" "$(sqt "DROP TABLE IF EXISTS $TDB.t2;")"
assert_error "重复 DROP TABLE 550" "$(sqt "DROP TABLE $TDB.t2;")" '550'

log "--- 清理 ---"
drop_table_dbs "$TDB"

md_case_finish table 'SHOW DATABASES;'
