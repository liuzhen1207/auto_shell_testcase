#!/bin/bash
# ============================================================================
# MD-C03 权限矩阵：权限值 × 路径粒度 × 用户/角色，与 LIST PRIVILEGES 逐条对应
#
# ⚠️ 前提说明（用户反馈后补齐）：**树模型与表模型的权限模型完全不同**，这条用例两种模型都覆盖：
#   树模型：READ/WRITE → 展开成 READ_DATA/READ_SCHEMA、WRITE_DATA/WRITE_SCHEMA；Scope 用 root.**
#           读是"按权限过滤"（无权限→空集、不报错），写是硬校验（803）；
#           且 **WRITE 隐含 READ**（源码 PathPrivilege.checkPrivilege：READ_DATA 检查回退到 WRITE_DATA）。
#   表模型：SELECT/INSERT/CREATE/DROP/ALTER/DELETE ON DATABASE|TABLE <名>（外加 MANAGE_USER/…）；
#           读写都是硬校验（无权限一律 803）；Scope 是 <库>.*。
#
# MD-C02 覆盖的是"用户/角色本身"的元数据闭环；这条专门打**权限矩阵**：
#   1) 权限值：READ / WRITE / ALL / SYSTEM / SECURITY / AUDIT 分别授出去后，
#      `LIST PRIVILEGES OF USER` 里出现的**粒度名**是什么（READ → READ_DATA + READ_SCHEMA）
#   2) 路径粒度：库级 `root.db.**` / 设备级 `root.db.d1` / 序列级 `root.db.d1.s1` / 全局 `root.**`
#      —— Scope 列必须**原样**反映授权时写的路径
#   3) 授予对象：直接授用户 vs 授角色再 `GRANT ROLE … TO …`（用户在 LIST 里能看到角色来的权限）
#   4) WITH GRANT OPTION：GrantOption 列必须为 true
#   5) 回收：REVOKE 后 LIST 里必须消失
#   6) **权限真的生效**：以该用户身份连上去 —— 只有 READ 时 SELECT 通过、INSERT 报 803；
#      补上 WRITE 后 INSERT 通过；只靠角色也能 SELECT；回收后再次报 803
#
# 实测要点（RC5）：
#   * `LIST PRIVILEGES OF USER/ROLE` 列为 Role|Scope|Privileges|GrantOption；
#     直接授予时 Role 为空，角色带来的权限 Role 列是角色名
#   * READ 会展开成 READ_DATA + READ_SCHEMA；WRITE 展开成 WRITE_DATA + WRITE_SCHEMA
#   * ALL / SYSTEM / SECURITY / AUDIT **只能授在 root.****（授在子路径报 701）
#   * 越权操作报 803（No permissions … please add privilege WRITE_DATA on [<path>]）
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_c03"
U="${MD_PREFIX}u_c03"
R="${MD_PREFIX}r_c03"
PW='MdProbe@123456'
md_case_init "md_privilege_matrix"
md_cluster_prepare

# 取 LIST PRIVILEGES 的某个集合（列 1=Role 2=Scope 3=Privileges 4=GrantOption）
priv_rows(){  md_rows "$1"; }
priv_list(){  md_count "$(md_rows "$1")"; }
priv_names(){ printf '%s\n' "$1" | md_col 3 | sort -u; }
priv_scopes(){ printf '%s\n' "$1" | md_col 2 | sort -u; }

log "--- 清理历史对象 ---"
q_tree "REVOKE ROLE $R FROM $U"
q_tree "DROP USER $U"
q_tree "DROP ROLE $R"
drop_tree_db "$DB"

log "=== 1) 准备：库/时序/数据/用户/角色 ==="
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_ok "建时序" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")"
assert_ok "建时序 s2" "$(sq "CREATE TIMESERIES $DB.d1.s2 INT32;")"
assert_ok "写入一行" "$(sq "INSERT INTO $DB.d1(timestamp, s1, s2) VALUES(1000, 1, 2);")"
assert_ok "建用户" "$(sq "CREATE USER $U '$PW';")"
assert_ok "建角色" "$(sq "CREATE ROLE $R;")"
assert_eq "初始无任何权限" "$(priv_list "$(sq "LIST PRIVILEGES OF USER $U;")")" "0"

log "=== 2) READ：粒度展开 + Scope 原样 = 授了 READ 会同时得到 READ_DATA / READ_SCHEMA ==="
assert_ok "GRANT READ ON $DB.**" "$(sq "GRANT READ ON $DB.** TO USER $U;")"
lst=$(sq "LIST PRIVILEGES OF USER $U;")
assert_eq "READ 展开成 2 行（DATA+SCHEMA）" "$(priv_list "$lst")" "2"
assert_set_is "READ 的粒度名集合" "$(priv_names "$lst")" "READ_DATA" "READ_SCHEMA"
assert_set_is "Scope 原样为授权路径" "$(priv_scopes "$lst")" "$DB.**"
assert_contains "GrantOption 为 false" "$lst" '\| *false *\|'

log "=== 3) 权限生效性：只有 READ 时能查不能写（803） ==="
assert_ok "以该用户 SELECT 成功" "$(sq_as "$U" "$PW" "SELECT s1 FROM $DB.d1;")"
assert_error "以该用户 INSERT 被拒 803" "$(sq_as "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(2000, 9);")" '803'

log "=== 4) 追加 WRITE：能写了；LIST 里出现 WRITE_* ==="
assert_ok "GRANT WRITE" "$(sq "GRANT WRITE ON $DB.** TO USER $U;")"
lst=$(sq "LIST PRIVILEGES OF USER $U;")
assert_eq "READ+WRITE 共 4 行" "$(priv_list "$lst")" "4"
assert_set_is "粒度名集合" "$(priv_names "$lst")" "READ_DATA" "READ_SCHEMA" "WRITE_DATA" "WRITE_SCHEMA"
assert_ok "以该用户 INSERT 成功" "$(sq_as "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(3000, 8);")"

log "=== 5) WITH GRANT OPTION ==="
assert_ok "回收后再带 GRANT OPTION 授予" "$(sq "REVOKE READ, WRITE ON $DB.** FROM USER $U;")"
assert_eq "回收后权限清空" "$(priv_list "$(sq "LIST PRIVILEGES OF USER $U;")")" "0"
assert_ok "GRANT READ, WRITE … WITH GRANT OPTION" "$(sq "GRANT READ, WRITE ON $DB.** TO USER $U WITH GRANT OPTION;")"
lst=$(sq "LIST PRIVILEGES OF USER $U;")
assert_eq "带 GRANT OPTION 时 4 行 GrantOption 全为 true" \
  "$(printf '%s\n' "$lst" | md_col 4 | grep -cx 'true')" "4"

log "=== 6) 路径粒度：序列级 / 全局 ==="
assert_ok "清空用户权限" "$(sq "REVOKE READ, WRITE ON $DB.** FROM USER $U;")"
assert_ok "GRANT READ ON 序列级 $DB.d1.s1" "$(sq "GRANT READ ON $DB.d1.s1 TO USER $U;")"
assert_set_is "Scope 必须是序列级路径" "$(priv_scopes "$(sq "LIST PRIVILEGES OF USER $U;")")" "$DB.d1.s1"
assert_ok "以该用户查该序列成功" "$(sq_as "$U" "$PW" "SELECT s1 FROM $DB.d1;")"
assert_ok "清空后再授 root.**" "$(sq "REVOKE READ ON $DB.d1.s1 FROM USER $U;")"
assert_ok "GRANT READ ON root.**" "$(sq "GRANT READ ON root.** TO USER $U;")"
assert_set_is "Scope 为 root.**" "$(priv_scopes "$(sq "LIST PRIVILEGES OF USER $U;")")" "root.**"
assert_ok "清空" "$(sq "REVOKE READ ON root.** FROM USER $U;")"

log "=== 7) ALL / SYSTEM / SECURITY / AUDIT 只能授在 root.** ==="
for p in ALL SYSTEM SECURITY AUDIT; do
  assert_error "$p 授在子路径必须报 701" "$(sq "GRANT $p ON $DB.** TO USER $U;")" '701'
  assert_ok "$p 授在 root.** 成功" "$(sq "GRANT $p ON root.** TO USER $U;")"
  got=$(priv_names "$(sq "LIST PRIVILEGES OF USER $U;")" | tr '\n' ',')
  log "  $p 在 root.** 上展开出的粒度名：$got"
  assert_ge "$p 至少出现 1 条粒度权限" "$(priv_list "$(sq "LIST PRIVILEGES OF USER $U;")")" "1"
  assert_ok "回收 $p" "$(sq "REVOKE $p ON root.** FROM USER $U;")"
  assert_eq "回收 $p 后权限为空" "$(priv_list "$(sq "LIST PRIVILEGES OF USER $U;")")" "0"
done

log "=== 8) 角色侧：授角色 → 用户继承 → 回收 ==="
assert_ok "GRANT READ ON <库> TO ROLE" "$(sq "GRANT READ ON $DB.** TO ROLE $R;")"
rlst=$(sq "LIST PRIVILEGES OF ROLE $R;")
assert_set_is "角色权限粒度名" "$(priv_names "$rlst")" "READ_DATA" "READ_SCHEMA"
assert_set_is "角色权限的 Role 列为角色名" "$(printf '%s\n' "$rlst" | md_col 1 | sort -u)" "$R"
assert_eq "未授角色前用户无直接权限" "$(priv_list "$(sq "LIST PRIVILEGES OF USER $U;")")" "0"
# 树模型的读是"按权限过滤"而不是"硬报错"：无权限路径读出来是空集（写才报 803）。
# 依据：源码 TreeAccessCheckVisitor 对 QUERY 取 getAuthorizedPathTree(READ_DATA) 做过滤；
#       AccessControlImpl 对表模型则是硬校验并返回 803。
noperm=$(sq_as "$U" "$PW" "SELECT s1 FROM $DB.d1;")
assert_ok "无权限用户查询不报错（返回空集而不是 803）" "$noperm"
assert_eq "无权限用户查询被过滤成空集" "$(md_count "$(md_rows "$noperm")")" "0"
assert_error "无权限用户写入才报 803（写是硬校验）" \
  "$(sq_as "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(4000, 7);")" '803'
assert_ok "GRANT ROLE" "$(sq "GRANT ROLE $R TO $U;")"
ulst=$(sq "LIST PRIVILEGES OF USER $U;")
assert_set_is "用户列表里出现角色带来的权限（Role 列=角色名）" "$(printf '%s\n' "$ulst" | md_col 1 | sort -u)" "$R"
assert_ok "通过角色可以查询" "$(sq_as "$U" "$PW" "SELECT s1 FROM $DB.d1;")"
assert_error "但角色只给了 READ，写入仍被拒 803" "$(sq_as "$U" "$PW" "INSERT INTO $DB.d1(timestamp, s1) VALUES(4000, 7);")" '803'
assert_ok "REVOKE ROLE" "$(sq "REVOKE ROLE $R FROM $U;")"
assert_set_lacks "回收角色后用户列表里不再有该角色权限" "$(printf '%s\n' "$(sq "LIST PRIVILEGES OF USER $U;")" | md_col 1)" "$R"

log "=== 9) 授予不存在的对象 ==="
assert_error "给不存在的用户授权报错" "$(sq "GRANT READ ON $DB.** TO USER ${MD_PREFIX}u_nosuch;")" ''
assert_error "给不存在的角色授权报错" "$(sq "GRANT READ ON $DB.** TO ROLE ${MD_PREFIX}r_nosuch;")" ''
assert_error "把不存在的角色授给用户报错" "$(sq "GRANT ROLE ${MD_PREFIX}r_nosuch TO $U;")" ''

# ---------------------------------------------------------------------------
# 树模型 vs 表模型的权限模型**完全不同**，这里做正面对照（用户反馈"是树还是表"引出的补充）
log "=== 10) 树模型：WRITE 隐含 READ（源码 PathPrivilege.checkPrivilege） ==="
UWO="${MD_PREFIX}u_c03wo"
q_tree "DROP USER $UWO"
assert_ok "建只授 WRITE 的用户" "$(sq "CREATE USER $UWO '$PW';")"
assert_ok "GRANT WRITE ON $DB.** TO USER" "$(sq "GRANT WRITE ON $DB.** TO USER $UWO;")"
wo=$(sq "LIST PRIVILEGES OF USER $UWO;")
assert_set_is "该用户只有 WRITE_DATA/WRITE_SCHEMA" "$(priv_names "$wo")" "WRITE_DATA" "WRITE_SCHEMA"
# 设计如此：checkPrivilege(READ_DATA) 会回退到 WRITE_DATA，checkPrivilege(READ_SCHEMA) 回退到 WRITE_SCHEMA
assert_ok "只授 WRITE 的用户也能读（WRITE 隐含 READ，设计如此）" \
  "$(sq_as "$UWO" "$PW" "SELECT s1 FROM $DB.d1;")"
assert_ge "而且确实读到了数据（前面步骤已写入若干行）" \
  "$(md_count "$(md_rows "$(sq_as "$UWO" "$PW" "SELECT s1 FROM $DB.d1;")")")" "1"

log "=== 11) 树模型：读是"按权限过滤"，跨库查询只返回有权限的部分 ==="
filtered=$(sq_as "$UWO" "$PW" "SELECT * FROM root.**;")
assert_ok "root.** 全库扫描不报错" "$filtered"
assert_contains "结果里只出现有权限的库 $DB" "$filtered" "${DB#root.}"
assert_not_contains "结果里不出现没权限的库（__system/__audit 等）" "$filtered" '__system'
assert_ok "清空该用户权限" "$(sq "REVOKE WRITE ON $DB.** FROM USER $UWO;")"
assert_eq "清空后 root.** 查询为空集" \
  "$(md_count "$(md_rows "$(sq_as "$UWO" "$PW" "SELECT * FROM root.**;")")")" "0"

log "=== 12) 表模型：权限模型与树模型完全不同（SELECT/INSERT… ON DATABASE|TABLE） ==="
MTDB="${MD_PREFIX}_c03t"
MTA="${MD_PREFIX}_c03ta"
MTB="${MD_PREFIX}_c03tb"
UM="${MD_PREFIX}u_c03t"
drop_table_dbs "$MTDB" "$MTA" "$MTB"
q_table "DROP USER $UM"
assert_ok "表模型建库" "$(sqt "CREATE DATABASE $MTDB;")"
assert_ok "表模型建库 A" "$(sqt "CREATE DATABASE $MTA;")"
assert_ok "表模型建库 B" "$(sqt "CREATE DATABASE $MTB;")"
assert_ok "表模型建表" "$(sqt "CREATE TABLE $MTDB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "表模型建表 A" "$(sqt "CREATE TABLE $MTA.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "表模型建表 B" "$(sqt "CREATE TABLE $MTB.t1 (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);")"
assert_ok "写入" "$(sqt "INSERT INTO $MTDB.t1 (time, dev, m1) VALUES (1700000000000, 'd1', 42);")"
assert_ok "建表模型用户" "$(sqt "CREATE USER $UM '$PW';")"
assert_ok "表模型授权语法：GRANT SELECT ON DATABASE <库> TO USER" "$(sqt "GRANT SELECT ON DATABASE $MTA TO USER $UM;")"
mlst=$(sqt "LIST PRIVILEGES OF USER $UM;")
assert_set_is "表模型的 Scope 是 <库>.* 而不是 root.**" "$(printf '%s\n' "$mlst" | md_col 2 | sort -u)" "$MTA.*"
assert_set_is "表模型的权限名是 SELECT（不是 READ_DATA）" "$(priv_names "$mlst")" "SELECT"
assert_eq "零权限时表模型读**报 803**（与树模型的空集不同）" \
  "$(md_count "$(md_rows "$(sqt_as "$UM" "$PW" "SELECT m1 FROM $MTDB.t1;")")")" "0"
assert_error "零权限时表模型读报 803" "$(sqt_as "$UM" "$PW" "SELECT m1 FROM $MTDB.t1;")" '803'
assert_ok "只授 SELECT 的表能读" "$(sqt_as "$UM" "$PW" "SELECT m1 FROM $MTA.t1;")"
assert_error "没授 SELECT 的表读报 803" "$(sqt_as "$UM" "$PW" "SELECT m1 FROM $MTB.t1;")" '803'
assert_error "只授 SELECT 不能写（803）" \
  "$(sqt_as "$UM" "$PW" "INSERT INTO $MTA.t1 (time, dev, m1) VALUES (1700000001000, 'd1', 9);")" '803'
assert_ok "补授 INSERT" "$(sqt "GRANT INSERT ON DATABASE $MTA TO USER $UM;")"
assert_ok "补授后能写" "$(sqt_as "$UM" "$PW" "INSERT INTO $MTA.t1 (time, dev, m1) VALUES (1700000001000, 'd1', 9);")"
assert_ok "清空表模型权限" "$(sqt "REVOKE SELECT, INSERT ON DATABASE $MTA FROM USER $UM;")"
note "行为记录（已与研发确认，非缺陷）：树模型的读是**按权限过滤**（无权限→空集，写才 803），且 WRITE 隐含 READ（源码 PathPrivilege.checkPrivilege）；表模型是硬校验（无 SELECT/INSERT 都报 803），且权限名/作用域语法与树模型完全不同（SELECT/INSERT ON DATABASE <库>）。"

log "--- 清理 ---"
q_tree "REVOKE ROLE $R FROM $U"
q_tree "REVOKE READ ON root.** FROM USER $U"
q_tree "REVOKE READ, WRITE ON $DB.** FROM USER $U"
q_tree "REVOKE READ ON $DB.** FROM ROLE $R"
q_tree "DROP USER $U"
q_tree "DROP USER $UWO"
q_tree "DROP ROLE $R"
drop_tree_db "$DB"
q_table "DROP USER $UM"
drop_table_dbs "$MTDB" "$MTA" "$MTB"
assert_set_lacks "清理后 LIST USER 不含该用户" "$(md_names_of 2 "$(sq 'LIST USER;')")" "$U"
assert_set_lacks "清理后 LIST ROLE 不含该角色" "$(md_names "$(sq 'LIST ROLE;')")" "$R"

md_case_finish tree "LIST PRIVILEGES OF USER $DB_USER;"
