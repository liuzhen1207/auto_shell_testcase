#!/bin/bash
# ============================================================================
# MD-T01 树模型 DATABASE 元数据闭环
#
# 覆盖：
#   建库（基础 / WITH TTL,TIME_PARTITION_INTERVAL / WITH NEED_LAST_CACHE）
#   SHOW DATABASES / SHOW DATABASES <path> / SHOW DATABASES DETAILS / COUNT DATABASES
#   ALTER DATABASE（NEED_LAST_CACHE 支持；TTL / TIME_PARTITION_INTERVAL 明确不支持）
#   DROP DATABASE（单个 / 一次多个）
#   失败路径：重复建（501）、删不存在的库（508）、未支持属性（700）、不支持 IF NOT EXISTS（700）、
#             在已有库下建同前缀子库
# 判据：所有"元数据集合"用排序后的行集合比对；错误路径断言错误码。
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t01"
DB2="root.${MD_PREFIX}_t01b"
DB3="root.${MD_PREFIX}_t01c"
DB4="root.${MD_PREFIX}_t01d"
md_case_init "md_tree_database"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_tree_dbs "$DB" "$DB2" "$DB3" "$DB4"

# ---------------------------------------------------------------------------
log "=== 1) 建库的三种写法 ==="
out=$(sq "CREATE DATABASE $DB;")
assert_ok "建库（基础）" "$out"
out=$(sq "CREATE DATABASE $DB2 WITH TTL=3600000, TIME_PARTITION_INTERVAL=86400000;")
assert_ok "建库（WITH TTL + TIME_PARTITION_INTERVAL）" "$out"
out=$(sq "CREATE DATABASE $DB3 WITH NEED_LAST_CACHE=false;")
assert_ok "建库（WITH NEED_LAST_CACHE=false）" "$out"

log "=== 2) SHOW DATABASES 集合 ==="
names=$(md_names "$(sq 'SHOW DATABASES;')")
assert_set_has "SHOW DATABASES 含 $DB"  "$names" "$DB"
assert_set_has "SHOW DATABASES 含 $DB2" "$names" "$DB2"
assert_set_has "SHOW DATABASES 含 $DB3" "$names" "$DB3"

log "=== 3) SHOW DATABASES <path> 只返回该库 ==="
one=$(sq "SHOW DATABASES $DB;")
assert_eq "SHOW DATABASES $DB 行数" "$(md_count "$(md_rows "$one")")" "1"
assert_set_is "SHOW DATABASES $DB 名字集合" "$(md_names "$one")" "$DB"

log "=== 4) COUNT DATABASES 与 SHOW DATABASES 行数一致 ==="
allrows=$(md_rows "$(sq 'SHOW DATABASES;')")
cnt=$(scalar "$(sq 'COUNT DATABASES;')")
assert_eq "COUNT DATABASES == SHOW DATABASES 行数" "$cnt" "$(md_count "$allrows")"

log "=== 5) SHOW DATABASES DETAILS 是 SHOW DATABASES 的加宽版 ==="
plain_cols=$(sq "SHOW DATABASES $DB;" | grep -E '^\+' | head -1 | tr -cd '-' | wc -c | tr -d ' ')
detail_out=$(sq "SHOW DATABASES DETAILS $DB;")
assert_ok "SHOW DATABASES DETAILS" "$detail_out"
detail_cols=$(printf '%s\n' "$detail_out" | grep -E '^\+' | head -1 | tr -cd '-' | wc -c | tr -d ' ')
assert_ge "DETAILS 列宽 > 普通列宽" "${detail_cols:-0}" "$(( ${plain_cols:-0} + 1 ))"
assert_set_has "DETAILS 仍含 $DB" "$(md_names "$detail_out")" "$DB"

log "=== 6) ALTER DATABASE：支持的（NEED_LAST_CACHE）与不支持的（TTL/TPI） ==="
out=$(sq "ALTER DATABASE $DB WITH NEED_LAST_CACHE=true;")
assert_ok "ALTER DATABASE WITH NEED_LAST_CACHE=true" "$out"
got=$(sq "SHOW DATABASES DETAILS $DB;" | md_last_col)
assert_eq "DETAILS 中 need_last_cache 已变为 true" "$got" "true"
assert_error "ALTER DATABASE WITH TTL（RC5 明确不支持，525）" "$(sq "ALTER DATABASE $DB WITH TTL=7200000;")" '525'
assert_error "ALTER DATABASE WITH TIME_PARTITION_INTERVAL（不支持，525）" "$(sq "ALTER DATABASE $DB WITH TIME_PARTITION_INTERVAL=7200000;")" '525'
assert_error "ALTER DATABASE 不存在的库" "$(sq "ALTER DATABASE root.${MD_PREFIX}_nosuch WITH NEED_LAST_CACHE=true;")" ''

log "=== 7) DROP DATABASE：单个 / 一次多个 / 幂等性 ==="
out=$(sq "DROP DATABASE $DB3;")
assert_ok "DROP DATABASE $DB3" "$out"
assert_set_lacks "删除后 SHOW DATABASES 不含 $DB3" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB3"
assert_error "重复 DROP DATABASE $DB3（508）" "$(sq "DROP DATABASE $DB3;")" '508'

# 多路径删除 vs 单路径删除：存在性校验**不一致**，但研发已确认这是**符合预期**的设计，故按现状写成硬断言。
#   单路径 DROP DATABASE <不存在>              -> 508，什么都不删
#   多路径 DROP DATABASE <存在>, <不存在>      -> 成功，把存在的那个删掉（静默跳过不存在的）
# 将来若两边统一了语义，这两条断言会 FAIL，提醒更新用例与文档。
log "  --- 多路径删除的对照实验（原始输出见下，可直接照抄复现）---"
single=$(sq "DROP DATABASE $DB4;")
log "    [单路径] DROP DATABASE $DB4  -> $(printf '%s' "$single" | tr '\n' ' ')"
assert_error "单路径删不存在的库报 508（已确认符合预期）" "$single" '508'
assert_set_has "单路径删除失败后 $DB2 仍在（没被误删）" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB2"
multi=$(sq "DROP DATABASE $DB2, $DB4;")
log "    [多路径] DROP DATABASE $DB2, $DB4  -> $(printf '%s' "$multi" | tr '\n' ' ')"
assert_ok "多路径（含不存在的库）整条语句成功（已确认符合预期）" "$multi"
assert_set_lacks "多路径删除后 $DB2 已被删除（存在的照删）" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB2"
assert_set_has "多路径删除不影响其他库（$DB 仍在）" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB"
note "行为记录（研发确认符合预期）：多路径 DROP DATABASE 逐个删除并静默跳过不存在的路径；单路径删不存在库报 508。四种写法（DROP/DELETE × DATABASE/STORAGE GROUP）一致。"

log "=== 8) 失败路径：重复建库 / 非法属性 / 不支持的 IF NOT EXISTS ==="
assert_error "重复建库（501）" "$(sq "CREATE DATABASE $DB;")" '501'
assert_error "建库带未支持属性（700）" "$(sq "CREATE DATABASE root.${MD_PREFIX}_t01e WITH NO_SUCH_KEY=1;")" '700'
assert_error "建库带 SCHEMA_REPLICATION_FACTOR（树模型 2.0 不支持，700）" \
  "$(sq "CREATE DATABASE root.${MD_PREFIX}_t01e WITH SCHEMA_REPLICATION_FACTOR=3;")" '700'
assert_error "CREATE DATABASE IF NOT EXISTS（RC5 不支持，700）" \
  "$(sq "CREATE DATABASE IF NOT EXISTS $DB;")" '700'
assert_error "DROP DATABASE IF EXISTS（RC5 不支持，700）" \
  "$(sq "DROP DATABASE IF EXISTS $DB;")" '700'

log "=== 9) 在已有库前缀下建库 ==="
assert_error "在已存在库下建同前缀子库（501）" "$(sq "CREATE DATABASE ${DB}.sub;")" '501'

log "=== 10) 清理并确认集合恢复 ==="
drop_tree_dbs "$DB" "$DB2"
names=$(md_names "$(sq 'SHOW DATABASES;')")
assert_set_lacks "清理后不含 $DB"  "$names" "$DB"
assert_set_lacks "清理后不含 $DB2" "$names" "$DB2"

md_case_finish tree 'SHOW DATABASES;'
