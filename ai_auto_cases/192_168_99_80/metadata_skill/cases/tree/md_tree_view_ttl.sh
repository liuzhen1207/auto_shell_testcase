#!/bin/bash
# ============================================================================
# MD-T06 树模型 VIEW 与 TTL 的元数据闭环
#
# 覆盖：
#   CREATE VIEW <目标路径> AS SELECT …（源为查询）/ CREATE VIEW <目标> AS <源路径序列>
#   SHOW VIEW / SHOW VIEW <path>（含类型、源路径列）
#   ALTER VIEW … RENAME TO（RC5 不支持，701）
#   DROP VIEW（幂等性：再删报 508）
#   SET TTL TO <path> <ms|INF> / SHOW TTL ON <path> / SHOW ALL TTL / UNSET TTL TO <path>
#
# 判据：视图与 TTL 都必须在 SHOW 系列里**如实**反映；删除后必须干净消失。
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t06"
V1="$DB.v1"
V2="$DB.v2"
V3="$DB.v3"
md_case_init "md_tree_view_ttl"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_tree_db "$DB"
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序 s1/s2" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")"
assert_ok "建时序 s2" "$(sq "CREATE TIMESERIES $DB.d1.s2 INT64;")"

# ---------------------------------------------------------------------------
log "=== 1) 建视图（两种写法） ==="
assert_ok "CREATE VIEW ... AS SELECT（源为查询）" "$(sq "CREATE VIEW $V1 AS SELECT s1 FROM $DB.d1;")"
# 目标路径个数必须与源路径个数一致（实测：1 对 2 会报 300）
assert_ok "CREATE VIEW <目标序列> AS <源路径序列>（个数一致）" "$(sq "CREATE VIEW $V2, $V3 AS $DB.d1.s1, $DB.d1.s2;")"
assert_error "目标 1 个 / 源 2 个（报 300）" "$(sq "CREATE VIEW $DB.vx AS $DB.d1.s1, $DB.d1.s2;")" '300'

log "=== 2) SHOW VIEW 必须列出三个视图及其源路径 ==="
views=$(sq 'SHOW VIEW;')
assert_ok "SHOW VIEW" "$views"
vnames=$(md_names "$views")
assert_set_has "SHOW VIEW 含 $V1" "$vnames" "$V1"
assert_set_has "SHOW VIEW 含 $V2" "$vnames" "$V2"
assert_set_has "SHOW VIEW 含 $V3" "$vnames" "$V3"
assert_contains "视图行标注类型 VIEW" "$views" 'VIEW'
one=$(sq "SHOW VIEW $V1;")
assert_set_is "SHOW VIEW <path> 只返回该视图" "$(md_names "$one")" "$V1"
assert_contains "视图行含源路径 $DB.d1.s1" "$one" "$DB\.d1\.s1"
assert_contains "第二个视图的源是 s1" "$(sq "SHOW VIEW $V2;")" 's1'
assert_contains "第三个视图的源是 s2" "$(sq "SHOW VIEW $V3;")" 's2'

log "=== 3) 视图与普通时序共用同一列出接口（已与研发确认，符合预期） ==="
tspaths=$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")
assert_set_has "SHOW TIMESERIES 含普通时序" "$tspaths" "$DB.d1.s1"
assert_set_has "SHOW TIMESERIES 也含视图路径（视图与普通时序共用列出接口，符合预期）" "$tspaths" "$V1"
assert_set_has "视图的多个目标路径都在 SHOW TIMESERIES 里" "$tspaths" "$V2"

log "=== 4) ALTER VIEW 的能力边界 ==="
assert_error "ALTER VIEW … RENAME TO（RC5 不支持，701）" "$(sq "ALTER VIEW $V1 RENAME TO $DB.v1r;")" '701'
assert_set_is "改名失败后 SHOW VIEW 集合不变" "$(md_names "$(sq 'SHOW VIEW;')")" "$V1" "$V2" "$V3"

log "=== 5) DROP VIEW 与幂等性 ==="
assert_ok "DROP VIEW $V3" "$(sq "DROP VIEW $V3;")"
assert_set_lacks "SHOW VIEW 不再含 $V3" "$(md_names "$(sq 'SHOW VIEW;')")" "$V3"
assert_error "重复 DROP VIEW（508）" "$(sq "DROP VIEW $V3;")" '508'

log "=== 6) TTL 元数据闭环 ==="
assert_ok "SET TTL TO <设备> 3600000" "$(sq "SET TTL TO $DB.d1 3600000;")"
ttl=$(sq "SHOW TTL ON $DB.d1;")
assert_contains "SHOW TTL ON 显示 3600000" "$ttl" '3600000'
allttl=$(sq 'SHOW ALL TTL;')
assert_contains "SHOW ALL TTL 含该设备路径" "$allttl" "$DB\.d1"
assert_contains "SHOW ALL TTL 含 3600000" "$allttl" '3600000'
assert_ok "SET TTL TO INF" "$(sq "SET TTL TO $DB.d1 INF;")"
assert_contains "SHOW TTL ON 变为 INF" "$(sq "SHOW TTL ON $DB.d1;")" 'INF'
assert_ok "SET TTL TO 0" "$(sq "SET TTL TO $DB.d1 0;")"
assert_contains "SHOW TTL ON 变为 0" "$(sq "SHOW TTL ON $DB.d1;")" '0'
assert_ok "UNSET TTL" "$(sq "UNSET TTL TO $DB.d1;")"
assert_eq "UNSET 后 SHOW TTL ON 该设备为空" "$(md_count "$(md_rows "$(sq "SHOW TTL ON $DB.d1;")")")" "0"
assert_ok "库级 TTL（SET TTL TO <库>）" "$(sq "SET TTL TO $DB 7200000;")"
assert_ok "库级 UNSET TTL" "$(sq "UNSET TTL TO $DB;")"

log "--- 清理 ---"
q_tree "DROP VIEW $V1"
q_tree "DROP VIEW $V2"
q_tree "DROP VIEW $V3"
drop_tree_db "$DB"

md_case_finish tree 'SHOW VIEW;'
