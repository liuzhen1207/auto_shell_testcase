#!/bin/bash
# ============================================================================
# MD-T03 树模型 SCHEMA TEMPLATE 元数据闭环
#
# 覆盖：
#   CREATE SCHEMA TEMPLATE / CREATE SCHEMA TEMPLATE ... ALIGNED (…) / CREATE DEVICE TEMPLATE
#   SHOW SCHEMA TEMPLATES（复数！单数 TEMPLATE 是语法错误 —— 见 MD-T05）
#   SHOW NODES IN SCHEMA TEMPLATE
#   SET SCHEMA TEMPLATE TO <db> / UNSET ... FROM <db>
#   SHOW PATHS SET SCHEMA TEMPLATE（模板挂载但未创建设备）
#   SHOW PATHS USING SCHEMA TEMPLATE（模板已激活的设备/前缀）
#   CREATE TIMESERIES USING SCHEMA TEMPLATE ON <path>
#   DELETE TIMESERIES OF SCHEMA TEMPLATE FROM <path> / DEACTIVATE SCHEMA TEMPLATE FROM <path>
#   ALTER SCHEMA TEMPLATE ... ADD (…)（只有 ADD，没有 DROP measurement）
#   DROP SCHEMA TEMPLATE + 失败路径（重复建 507、模板占用中 515、未激活 524）
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t03"
DB2="root.${MD_PREFIX}_t03b"
TPL="tpl_${MD_PREFIX}_t03"
TPL2="tpl_${MD_PREFIX}_t03b"
md_case_init "md_tree_template"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_templates "$TPL" "$TPL2"
drop_tree_dbs "$DB" "$DB2"
assert_ok "建库 $DB"  "$(sq "CREATE DATABASE $DB;")"
assert_ok "建库 $DB2" "$(sq "CREATE DATABASE $DB2;")"

# ---------------------------------------------------------------------------
log "=== 1) 建模板（普通 / ALIGNED / DEVICE 关键字） ==="
assert_ok "建模板（普通）" "$(sq "CREATE SCHEMA TEMPLATE $TPL (s1 INT32, s2 FLOAT);")"
assert_ok "建模板（ALIGNED，关键字在名字之后、测量列表之前）" "$(sq "CREATE SCHEMA TEMPLATE $TPL2 ALIGNED (a1 INT32, a2 INT64);")"
assert_ok "CREATE DEVICE TEMPLATE 等价写法" "$(sq "CREATE DEVICE TEMPLATE ${TPL}_dev (x INT32);")"

log "=== 2) SHOW SCHEMA TEMPLATES（复数） ==="
tpls=$(sq "SHOW SCHEMA TEMPLATES;")
assert_ok "SHOW SCHEMA TEMPLATES" "$tpls"
assert_set_has "模板列表含 $TPL"  "$(md_names "$tpls")" "$TPL"
assert_set_has "模板列表含 $TPL2" "$(md_names "$tpls")" "$TPL2"

log "=== 3) SHOW NODES IN SCHEMA TEMPLATE 必须列出模板内的测量 ==="
nodes=$(sq "SHOW NODES IN SCHEMA TEMPLATE $TPL;")
assert_ok "SHOW NODES IN SCHEMA TEMPLATE" "$nodes"
assert_contains "模板含测量 s1" "$nodes" 's1'
assert_contains "模板含测量 s2" "$nodes" 's2'

log "=== 4) SET / UNSET SCHEMA TEMPLATE 的元数据可见性 ==="
assert_ok "SET SCHEMA TEMPLATE TO $DB" "$(sq "SET SCHEMA TEMPLATE $TPL TO $DB;")"
setpaths=$(sq "SHOW PATHS SET SCHEMA TEMPLATE $TPL;")
assert_set_is "SHOW PATHS SET 返回挂载点 $DB" "$(md_names "$setpaths")" "$DB"
assert_eq "挂载但未建设备时 SHOW PATHS USING 为空" \
  "$(md_count "$(md_rows "$(sq "SHOW PATHS USING SCHEMA TEMPLATE $TPL;")")")" "0"

log "=== 5) CREATE TIMESERIES USING SCHEMA TEMPLATE 后 USING 路径出现 ==="
assert_ok "CREATE TIMESERIES USING SCHEMA TEMPLATE ON $DB.dev1" "$(sq "CREATE TIMESERIES USING SCHEMA TEMPLATE ON $DB.dev1;")"
# 注意：`SHOW PATHS <前缀> USING …` 实测返回空集，不带前缀才列全部激活路径（本轮实测）
using=$(sq "SHOW PATHS USING SCHEMA TEMPLATE $TPL;")
assert_set_is "SHOW PATHS USING 返回设备 $DB.dev1" "$(md_names "$using")" "$DB.dev1"
ts=$(md_names "$(sq "SHOW TIMESERIES $DB.dev1.**;")")
assert_set_has "模板建设备后时序 s1 存在" "$ts" "$DB.dev1.s1"
assert_set_has "模板建设备后时序 s2 存在" "$ts" "$DB.dev1.s2"
assert_set_has "SHOW DEVICES 出现该设备" "$(md_names "$(sq "SHOW DEVICES $DB.**;")")" "$DB.dev1"
assert_contains "SHOW DEVICES WHERE TEMPLATE 可过滤模板设备" \
  "$(sq "SHOW DEVICES $DB.** WHERE TEMPLATE = '$TPL';")" "$DB.dev1"

log "=== 6) ALTER SCHEMA TEMPLATE ADD (…) ==="
assert_ok "ALTER SCHEMA TEMPLATE ADD (s3 INT64)" "$(sq "ALTER SCHEMA TEMPLATE $TPL ADD (s3 INT64);")"
assert_contains "模板测量中新增 s3" "$(sq "SHOW NODES IN SCHEMA TEMPLATE $TPL;")" 's3'
assert_error "ALTER SCHEMA TEMPLATE DROP measurement（RC5 不支持，700）" \
  "$(sq "ALTER SCHEMA TEMPLATE $TPL DROP (s3);")" '700'
assert_error "ALTER SCHEMA TEMPLATE 不带括号（700）" \
  "$(sq "ALTER SCHEMA TEMPLATE $TPL ADD s3 INT64;")" '700'

log "=== 7) 卸载模板的前置条件 ==="
assert_error "设备仍在使用时 UNSET（515）" "$(sq "UNSET SCHEMA TEMPLATE $TPL FROM $DB;")" '515'
assert_ok "DELETE TIMESERIES OF SCHEMA TEMPLATE FROM 设备" \
  "$(sq "DELETE TIMESERIES OF SCHEMA TEMPLATE FROM $DB.dev1;")"
assert_set_lacks "删除后 USING 路径不再含 dev1" \
  "$(md_names "$(sq "SHOW PATHS USING SCHEMA TEMPLATE $TPL;")")" "$DB.dev1"assert_set_has "SET 路径仍记录挂载点" "$(md_names "$(sq "SHOW PATHS SET SCHEMA TEMPLATE $TPL;")")" "$DB"

log "=== 8) 二库挂载 + 卸载 ==="
assert_ok "第二个库挂载同一模板" "$(sq "SET SCHEMA TEMPLATE $TPL TO $DB2;")"
setpaths=$(md_names "$(sq "SHOW PATHS SET SCHEMA TEMPLATE $TPL;")")
assert_set_is "SHOW PATHS SET 现在有 $DB 与 $DB2" "$setpaths" "$DB" "$DB2"
assert_error "重复 SET 到同一路径（507）" "$(sq "SET SCHEMA TEMPLATE $TPL TO $DB2;")" '507'
assert_ok "UNSET FROM $DB"  "$(sq "UNSET SCHEMA TEMPLATE $TPL FROM $DB;")"
assert_ok "UNSET FROM $DB2" "$(sq "UNSET SCHEMA TEMPLATE $TPL FROM $DB2;")"
assert_eq "全部卸载后 SHOW PATHS SET 为空" \
  "$(md_count "$(md_rows "$(sq "SHOW PATHS SET SCHEMA TEMPLATE $TPL;")")")" "0"
assert_error "重复 UNSET（513）" "$(sq "UNSET SCHEMA TEMPLATE $TPL FROM $DB;")" '513'

log "=== 9) DROP SCHEMA TEMPLATE ==="
assert_ok "DROP SCHEMA TEMPLATE $TPL2" "$(sq "DROP SCHEMA TEMPLATE $TPL2;")"
assert_set_lacks "模板列表中不再有 $TPL2" "$(md_names "$(sq "SHOW SCHEMA TEMPLATES;")")" "$TPL2"
assert_error "DROP 不存在的模板（507）" "$(sq "DROP SCHEMA TEMPLATE nosuchtpl_x;")" '507'
assert_error "重复 DROP（507）" "$(sq "DROP SCHEMA TEMPLATE $TPL2;")" '507'
assert_error "重复建同名模板（507）" "$(sq "CREATE SCHEMA TEMPLATE $TPL (s1 INT32);")" '507'
assert_error "CREATE SCHEMA TEMPLATE IF NOT EXISTS（RC5 不支持，700）" \
  "$(sq "CREATE SCHEMA TEMPLATE IF NOT EXISTS $TPL (s1 INT32);")" '700'

log "--- 清理 ---"
q_tree "DROP TIMESERIES OF SCHEMA TEMPLATE FROM $DB.dev1"
drop_templates "$TPL" "${TPL}_dev"
drop_tree_dbs "$DB" "$DB2"

md_case_finish tree 'SHOW SCHEMA TEMPLATES;'
