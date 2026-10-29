#!/bin/bash
# ============================================================================
# MD-C02 权限元数据（USER / ROLE / PRIVILEGE）闭环
#
# 覆盖：
#   CREATE USER（口令长度下限 12）/ LIST USER
#   CREATE ROLE / LIST ROLE
#   GRANT <权限> ON <路径> TO USER|ROLE / REVOKE … FROM USER|ROLE
#   GRANT ROLE r TO u / REVOKE ROLE r FROM u（注意：这里**不能**写 TO USER，见语法）
#   LIST PRIVILEGES OF USER|ROLE / LIST ROLE OF USER / LIST USER OF ROLE
#   ALTER USER SET PASSWORD / SET MAX_SESSION_PER_USER / RENAME TO
#   失败路径：口令过短 820、删不存在的用户 804、删不存在的角色 808、GRANT ROLE … TO USER（700 语法）
#
# 判据：授权/回收必须在 LIST 系列里**双向**反映（用户侧与角色侧都要对）。
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

U="${MD_PREFIX}u_c02"
U2="${MD_PREFIX}u_c02b"
R="${MD_PREFIX}r_c02"
DB="root.${MD_PREFIX}_c02"
md_case_init "md_dcl_user_role"
md_cluster_prepare

log "--- 清理历史对象 ---"
q_tree "DROP USER $U"
q_tree "DROP USER $U2"
q_tree "DROP ROLE $R"
drop_tree_db "$DB"
assert_ok "建库（用于授权路径）" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")"

# ---------------------------------------------------------------------------
log "=== 1) 建用户 / 角色 ==="
assert_ok "CREATE USER（口令 ≥12）" "$(sq "CREATE USER $U 'MdProbe@123456';")"
assert_ok "CREATE ROLE"             "$(sq "CREATE ROLE $R;")"
# LIST USER 的列是 `id|user|...`，名字在第 2 列；LIST ROLE 只有一列（角色名）
assert_set_has "LIST USER 含新用户" "$(md_names_of 2 "$(sq 'LIST USER;')")" "$U"
assert_set_has "LIST ROLE 含新角色" "$(md_names "$(sq 'LIST ROLE;')")" "$R"
assert_error "重复建用户（报错）" "$(sq "CREATE USER $U 'MdProbe@123456';")" ''
assert_error "重复建角色（报错）" "$(sq "CREATE ROLE $R;")" ''

log "=== 2) 授权：直接授给用户 ==="
assert_ok "GRANT READ ON <路径> TO USER" "$(sq "GRANT READ ON $DB.** TO USER $U;")"
privs=$(sq "LIST PRIVILEGES OF USER $U;")
assert_contains "用户权限列表含授权路径" "$privs" "$DB\.\*\*"
assert_contains "用户权限列表含 READ_DATA" "$privs" 'READ_DATA'

log "=== 3) 授权：授给角色，再把角色给用户 ==="
assert_ok "GRANT READ ON <路径> TO ROLE" "$(sq "GRANT READ ON $DB.** TO ROLE $R;")"
assert_contains "角色权限列表含授权路径" "$(sq "LIST PRIVILEGES OF ROLE $R;")" "$DB\.\*\*"
assert_ok "GRANT ROLE r TO u（注意不带 USER 关键字）" "$(sq "GRANT ROLE $R TO $U;")"
assert_contains "LIST ROLE OF USER 含该角色" "$(sq "LIST ROLE OF USER $U;")" "$R"
assert_contains "LIST USER OF ROLE 含该用户" "$(sq "LIST USER OF ROLE $R;")" "$U"
assert_error "GRANT ROLE … TO USER（RC5 语法不接受 USER，700）" "$(sq "GRANT ROLE $R TO USER $U;")" '700'

log "=== 4) 回收 ==="
assert_ok "REVOKE ROLE FROM USER" "$(sq "REVOKE ROLE $R FROM $U;")"
assert_set_lacks "回收后 LIST ROLE OF USER 为空" "$(md_names "$(sq "LIST ROLE OF USER $U;")")" "$R"
assert_ok "REVOKE 权限 FROM USER" "$(sq "REVOKE READ ON $DB.** FROM USER $U;")"
assert_set_lacks "回收后用户权限列表不含该路径" \
  "$(printf '%s\n' "$(sq "LIST PRIVILEGES OF USER $U;")" | md_col 2)" "$DB.**"
assert_ok "REVOKE 权限 FROM ROLE" "$(sq "REVOKE READ ON $DB.** FROM ROLE $R;")"

log "=== 5) ALTER USER ==="
assert_ok "SET PASSWORD" "$(sq "ALTER USER $U SET PASSWORD 'MdProbe@654321';")"
assert_ok "SET MAX_SESSION_PER_USER" "$(sq "ALTER USER $U SET MAX_SESSION_PER_USER 5;")"
assert_ok "RENAME TO 新用户名" "$(sq "ALTER USER $U RENAME TO $U2;")"
names=$(md_names_of 2 "$(sq 'LIST USER;')")
assert_set_has   "LIST USER 含改名后的 $U2" "$names" "$U2"
assert_set_lacks "LIST USER 不再含旧名 $U"  "$names" "$U"

log "=== 6) 失败路径 ==="
assert_error "口令过短 820" "$(sq "CREATE USER ${MD_PREFIX}u_short 'short';")" '820'
assert_error "删除不存在的用户 804" "$(sq "DROP USER ${MD_PREFIX}u_nosuch;")" '804'
assert_error "删除不存在的角色 808" "$(sq "DROP ROLE ${MD_PREFIX}r_nosuch;")" '808'
assert_error "给不存在的用户授权（报错）" "$(sq "GRANT READ ON $DB.** TO USER ${MD_PREFIX}u_nosuch;")" ''

log "=== 7) 删除后元数据干净 ==="
assert_ok "DROP USER $U2" "$(sq "DROP USER $U2;")"
assert_ok "DROP ROLE $R"  "$(sq "DROP ROLE $R;")"
names=$(md_names_of 2 "$(sq 'LIST USER;')")
assert_set_lacks "LIST USER 不再含 $U2" "$names" "$U2"
assert_set_lacks "LIST ROLE 不再含 $R"  "$(md_names "$(sq 'LIST ROLE;')")" "$R"
assert_error "重复 DROP USER 804" "$(sq "DROP USER $U2;")" '804'
assert_error "重复 DROP ROLE 808"  "$(sq "DROP ROLE $R;")" '808'

log "--- 清理 ---"
drop_tree_db "$DB"

md_case_finish tree 'LIST USER;'
