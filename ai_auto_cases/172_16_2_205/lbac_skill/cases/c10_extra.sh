# ============================================================================
# LBAC 补充用例 LB-142 ~ LB-160（绑定生命周期 / 查询表达式 / 权限级联 / 旁路）
#   其中 LB-143/144/146/154/158/159/160 为 SKIP（需求待确认或语法不支持）
# ============================================================================

CASES+=(
"LB-142|绑定|正向|表切换到另一策略：解绑旧策略后按新策略重新保护列|case_LB142"
"LB-143|绑定|边界|保护 TAG 列 / TIME 列（待需求确认）|case_LB143"
"LB-144|绑定|边界|RENAME TABLE 后策略与列标签保持（语法不支持）|case_LB144"
"LB-145|绑定|正向|DROP COLUMN 删除受保护列后该标签可被删除|case_LB145"
"LB-146|绑定|边界|CREATE TABLE AS SELECT / LIKE 不继承策略（语法不支持）|case_LB146"
"LB-147|查询|反向|聚合函数 COUNT/SUM/AVG 引用受保护列触发读检查|case_LB147"
"LB-148|查询|反向|GROUP BY / HAVING / ORDER BY 引用受保护列触发读检查|case_LB148"
"LB-149|查询|反向|WHERE 过滤条件引用受保护列触发读检查|case_LB149"
"LB-150|查询|反向|SELECT 别名不能绕过受保护列读检查|case_LB150"
"LB-151|查询|反向|JOIN 两张不同标签的表按 AND 语义判定|case_LB151"
"LB-152|查询|反向|UNION / 子查询引用受保护列触发读检查|case_LB152"
"LB-153|权限|反向|仅有 LBAC 凭证、无 RBAC 权限仍被拒（803）|case_LB153"
"LB-154|权限|边界|同一策略 READ 与 WRITE 授予不同标签（待需求确认）|case_LB154"
"LB-155|权限|正向|DROP USER 后 label 授权与豁免级联清理|case_LB155"
"LB-156|授权|正向|GRANT EXEMPTION TO ROLE 生效且受 IGNORE 影响|case_LB156"
"LB-157|权限|正向|三权分立：security_admin 授 label 给 sys_admin 后仍无数据权限|case_LB157"
"LB-158|旁路|边界|EXPORT / SELECT INTO 导出受保护列是否受检（待需求确认）|case_LB158"
"LB-159|旁路|边界|pipe / subscription 写入受保护列是否受检（待需求确认）|case_LB159"
"LB-160|旁路|边界|LOAD / 批量导入受保护列是否受检（待需求确认）|case_LB160"
)

SKIP_OF["LB-143"]="待需求确认：TAG / TIME 列是否允许 SECURED WITH（需求未写，暂不判定）"
SKIP_OF["LB-144"]="表模型不支持 RENAME TABLE（RENAME 语法报 700），无法验证"
SKIP_OF["LB-146"]="表模型不支持 CREATE TABLE ... AS SELECT / LIKE（语法报 700），无继承路径"
SKIP_OF["LB-154"]="待需求确认：同一策略下 READ 与 WRITE 能否授予不同标签"
SKIP_OF["LB-158"]="待需求确认：导出链路（EXPORT / SELECT INTO）是否在 LBAC 检查范围"
SKIP_OF["LB-159"]="待需求确认：pipe / subscription 写入是否在 LBAC 检查范围"
SKIP_OF["LB-160"]="待需求确认：LOAD / 批量导入是否在 LBAC 检查范围"
if [ "${SEP:-0}" != "1" ]; then
  SKIP_OF["LB-157"]="仅三权分立场景（SEP=1）验证跨管理员权限边界"
fi

# 释放 with_label 临时用户占用的标签授权，便于验证「无引用后可删」
drop_lbu_users() {
  local rows x
  rows=$(Q "LIST USER" 2>/dev/null | awk -F'|' 'NF>3 {gsub(/ /,"",$3); if ($3 ~ /^lbu_/) print $3}')
  for x in $rows; do Q "DROP USER $x" >/dev/null 2>&1; done
  sleep 1
}

# 通用环境：t1.s1 受 sec 保护，插一行数据（t1.s2 未保护）
extra_env() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2) VALUES(1,'d1',1.5,2.5)" >/dev/null 2>&1
}

case_LB142() {
  extra_env
  local o
  if [ "${SEP:-0}" = "1" ]; then
    # 三权分立：DROP SECURITY POLICY 需 ALTER(sys) + SECURITY(security)，由 security_admin 自授 ALTER 后执行
    QS "GRANT ALTER ON DATABASE $DB TO USER ${SEC_ADMIN}" >/dev/null 2>&1
    sleep 2
    o=$(L "$SEC_ADMIN" "$ADMIN_PW" "ALTER TABLE $DB.t1 DROP SECURITY POLICY")
  else
    o=$(Q "ALTER TABLE $DB.t1 DROP SECURITY POLICY")
  fi
  assert_ok "$o" "解绑旧策略（同时清列标签）"
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl2 ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl2" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p2.a COMPONENT lb_lvl2 'A'" >/dev/null 2>&1
  bind_policy t1 lb_p2
  assert_contains "$(Q "SELECT table_name, security_policy FROM information_schema.tables" | grep -E '\| *t1 *\|')" "lb_p2" "新策略已绑定"
  assert_ok "$(with_label a "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH a" lb_p2)" "按新策略重新保护列"
  if verify_col_label s1 a; then
    ok "列标签已切换到新策略的 a"
  else
    fail "列标签未切换（实际：$(Q "SELECT column_name, security_label FROM information_schema.columns" | grep -E '\| *s1 *\|' | tr '\n' ' ' | cut -c1-120)）"
  fi
  local u; u=$(mk_user c142)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "无凭证读新保护列被拒"
}

case_LB145() {
  extra_env
  drop_lbu_users
  assert_ok "$(with_label sec "ALTER TABLE $DB.t1 DROP COLUMN s1")" "删除受保护列（持写凭证）"
  assert_no_rows "$(Q "SELECT column_name, security_label FROM information_schema.columns" | grep -E '\| *s1 *\|')" "受保护列已从元数据移除"
  drop_lbu_users
  assert_ok "$(Q "DROP SECURITY LABEL lb_p.sec")" "列引用与授权均释放后标签可被删除"
}

case_LB147() {
  extra_env
  local u; u=$(mk_user c147)
  assert_err "$(u_sql "$u" "SELECT COUNT(s1) FROM $DB.t1")" "2400" "COUNT(受保护列) 触发读检查"
  assert_err "$(u_sql "$u" "SELECT SUM(s1) FROM $DB.t1")" "2400" "SUM(受保护列) 触发读检查"
  assert_ok "$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1")" "COUNT(*) 不触发读检查"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT SUM(s1), AVG(s1), COUNT(s1) FROM $DB.t1")" "授予读凭证后聚合可用"
}

case_LB148() {
  extra_env
  local u; u=$(mk_user c148)
  assert_err "$(u_sql "$u" "SELECT dev, COUNT(s1) FROM $DB.t1 GROUP BY dev")" "2400" "GROUP BY + 聚合受保护列被拒"
  assert_err "$(u_sql "$u" "SELECT dev, SUM(s2) FROM $DB.t1 GROUP BY dev HAVING SUM(s1) > 0")" "2400" "HAVING 引用受保护列被拒"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1 ORDER BY s1")" "2400" "ORDER BY 受保护列被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT dev, COUNT(s1) FROM $DB.t1 GROUP BY dev")" "授予读凭证后 GROUP BY 可用"
}

case_LB149() {
  extra_env
  local u; u=$(mk_user c149)
  assert_err "$(u_sql "$u" "SELECT s2 FROM $DB.t1 WHERE s1 > 1")" "2400" "WHERE 引用受保护列被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s2 FROM $DB.t1 WHERE s1 > 1")" "授予读凭证后 WHERE 可用"
}

case_LB150() {
  extra_env
  local u; u=$(mk_user c150)
  assert_err "$(u_sql "$u" "SELECT s1 AS x FROM $DB.t1")" "2400" "别名投影不能绕过检查"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  local o; o=$(u_sql "$u" "SELECT s1 AS x FROM $DB.t1")
  assert_ok "$o" "授予读凭证后别名投影成功"
  assert_contains "$o" "1.5" "别名结果正确"
}

case_LB151() {
  obj_env
  mk_table t1
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2) VALUES(1,'d1',1.5,2.5)" >/dev/null 2>&1
  # 第二张表用独立策略，便于同一用户同时持有两个策略的标签
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl2 ARRAY ('TOP','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl2" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p2.top COMPONENT lb_lvl2 'TOP'" >/dev/null 2>&1
  Q "CREATE TABLE IF NOT EXISTS $DB.t2(time TIMESTAMP TIME, dev STRING TAG, s1 DOUBLE FIELD, s2 DOUBLE FIELD)" >/dev/null 2>&1
  bind_policy t2 lb_p2
  with_label top "ALTER TABLE $DB.t2 ALTER COLUMN s1 SECURED WITH top" lb_p2 >/dev/null 2>&1
  with_label top "INSERT INTO $DB.t2(time,dev,s1,s2) VALUES(1,'d1',9.5,8.5)" lb_p2 >/dev/null 2>&1
  local u; u=$(mk_user c151)
  Q "GRANT SELECT ON TABLE $DB.t2 TO USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT a.s1, b.s1 FROM $DB.t1 a JOIN $DB.t2 b ON a.dev = b.dev")" "2400" "JOIN 中无权的那张表被拒（AND 语义）"
  Q "GRANT SECURITY LABEL lb_p2.top TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT a.s1, b.s1 FROM $DB.t1 a JOIN $DB.t2 b ON a.dev = b.dev")" "两个策略的凭证齐全后 JOIN 允许"
}

case_LB152() {
  extra_env
  local u; u=$(mk_user c152)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1 UNION SELECT s1 FROM $DB.t1")" "2400" "UNION 引用受保护列被拒"
  assert_err "$(u_sql "$u" "SELECT s2 FROM $DB.t1 WHERE dev IN (SELECT dev FROM $DB.t1 WHERE s1 > 1)")" "2400" "子查询引用受保护列被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1 UNION SELECT s1 FROM $DB.t1")" "授予读凭证后 UNION 可用"
}

case_LB153() {
  extra_env
  local u="lbu_c153"
  Q "DROP USER $u" >/dev/null 2>&1
  Q "CREATE USER $u '$UPW'" >/dev/null 2>&1
  local i=0; while [ $i -lt 15 ]; do Q "LIST USER" 2>/dev/null | grep -q "$u" && break; sleep 1; i=$((i+1)); done
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_contains "$(Q "SELECT grantee, label_name FROM information_schema.security_label_access" | grep "$u")" "sec" "LBAC 授权已建立"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "803" "仅有 LBAC 凭证、无 RBAC SELECT 仍被拒"
  Q "GRANT SELECT ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "补齐 RBAC 后允许"
}

case_LB155() {
  extra_env
  drop_lbu_users
  local u; u=$(mk_user c155)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u" >/dev/null 2>&1
  assert_contains "$(Q "SELECT grantee, label_name FROM information_schema.security_label_access" | grep "$u")" "sec" "授权已建立"
  assert_contains "$(Q "SELECT grantee FROM information_schema.security_policy_exemptions" | grep "$u")" "$u" "豁免已建立"
  assert_ok "$(Q "DROP USER $u")" "删除用户成功"
  assert_no_rows "$(Q "SELECT grantee FROM information_schema.security_label_access" | grep "$u")" "label 授权记录级联清理"
  assert_no_rows "$(Q "SELECT grantee FROM information_schema.security_policy_exemptions" | grep "$u")" "豁免记录级联清理"
  assert_ok "$(with_label sec "ALTER TABLE $DB.t1 DROP COLUMN s1")" "删除受保护列释放标签引用"
  drop_lbu_users
  assert_ok "$(Q "DROP SECURITY LABEL lb_p.sec")" "无引用后标签可被删除"
}

case_LB156() {
  extra_env
  drop_lbu_users
  local u r
  u=$(mk_user c156u); r=$(mk_role c156)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO ROLE $r")" "豁免授予角色成功"
  assert_contains "$(Q "SELECT grantee_type, grantee FROM information_schema.security_policy_exemptions" | grep "$r")" "ROLE" "豁免记录 grantee_type=ROLE"
  # 默认 IGNORE：角色豁免不参与
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "默认 IGNORE 模式下角色豁免不生效"
  Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  sleep 3
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "切换 USE 后角色豁免生效（可读 sec 保护列）"
  Q "ALTER SECURITY POLICY lb_p IGNORE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  format_ignore_placeholder=1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "再切回 IGNORE 后角色豁免失效"
}

case_LB157() {
  extra_env
  assert_ok "$(QS "GRANT SECURITY LABEL lb_p.sec TO USER $SYS_ADMIN FOR ALL ACCESS")" "security_admin 可把标签授予 sys_admin"
  assert_contains "$(QS "SELECT grantee, label_name FROM information_schema.security_label_access" | grep "$SYS_ADMIN")" "sec" "sys_admin 已有 LBAC 凭证"
  assert_err "$(QD "SELECT s1 FROM $DB.t1")" "803" "sys_admin 有凭证但无 RBAC SELECT 仍被拒"
}
