# ============================================================================
# LBAC 对象绑定与视图用例 LB-097 ~ LB-110
# ============================================================================

declare -A SKIP_OF=()
SKIP_OF["LB-109"]="不适用（已确认）：可写视图源为树模型（VIEW FROM TREE），不做 LBAC 保护；逻辑视图场景见 LB-110"
SKIP_OF["LB-122"]="同上（可写视图写入检查）"

CASES+=(
"LB-097|绑定|正向|CREATE TABLE 同时绑定策略与列保护生效|case_LB097"
"LB-098|绑定|异常|建表时 SECURED WITH 标签不属于该策略报错|case_LB098"
"LB-099|绑定|异常|建表时绑定不存在的策略报错|case_LB099"
"LB-100|绑定|正向|ALTER TABLE ADD SECURITY POLICY 成功|case_LB100"
"LB-101|绑定|异常|表已绑定策略后再次 ADD 报错|case_LB101"
"LB-102|绑定|反向|新增列保护需要新标签写凭证（无凭证拒绝）|case_LB102"
"LB-103|绑定|反向|修改列保护需要旧标签读写 + 新标签写（缺一即拒）|case_LB103"
"LB-104|绑定|边界|修改列保护为新标签且凭证齐全时成功|case_LB104"
"LB-105|绑定|边界|SECURED WITH 相同标签在凭证齐全时幂等成功|case_LB105"
"LB-106|绑定|反向|解除列保护需要旧标签读写凭证|case_LB106"
"LB-107|绑定|正向|DROP SECURITY POLICY 同时移除表策略与全部列标签|case_LB107"
"LB-108|绑定|异常|视图（可写视图/逻辑视图）不能设置 LBAC 保护|case_LB108"
"LB-109|视图|正向|可写视图 CRUD 走底层表的 LBAC 检查|case_LB109"
"LB-110|视图|正向|逻辑视图查询走底层表的 LBAC 检查|case_LB110"
)

# 环境：level 组件 + 策略 + 3 标签（top/sec/pub），root 授权，表未绑定
obj_env() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('TOP','SEC','INT','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local l
  for l in top sec int pub; do
    Q "CREATE SECURITY LABEL lb_p.$l COMPONENT lb_lvl '$(echo "$l" | tr a-z A-Z)'" >/dev/null 2>&1
    Q "GRANT SECURITY LABEL lb_p.$l TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  done
}

case_LB097() {
  obj_env
  local o
  o=$(with_label sec "CREATE TABLE $DB.t_sec(time TIMESTAMP TIME, dev STRING TAG, s1 DOUBLE FIELD SECURED WITH sec, s2 DOUBLE FIELD) SECURITY POLICY lb_p")
  assert_ok "$o" "建表时绑定策略并保护列"
  assert_contains "$(Q "SELECT table_name, security_policy FROM information_schema.tables" | grep t_sec)" "lb_p" "表策略已记录"
  assert_contains "$(Q "SELECT table_name, column_name, security_label FROM information_schema.columns" | grep t_sec)" "sec" "列标签已记录"
  # 保护生效：无凭证用户读被拒
  local u; u=$(mk_user c97)
  Q "GRANT SELECT ON TABLE $DB.t_sec TO USER $u" >/dev/null 2>&1
  with_label sec "INSERT INTO $DB.t_sec(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t_sec")" "2400" "受保护列对新用户生效"
}

case_LB098() {
  obj_env
  Q "CREATE SECURITY LABEL COMPONENT lb_other SET ('X')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_other" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p2.otherl COMPONENT lb_other 'X'" >/dev/null 2>&1
  local o
  o=$(Q "CREATE TABLE $DB.t_bad(time TIMESTAMP TIME, dev STRING TAG, s1 DOUBLE FIELD SECURED WITH otherl) SECURITY POLICY lb_p")
  assert_err "$o" "" "标签不属于策略时报错"
}

case_LB099() {
  obj_env
  local o
  o=$(Q "CREATE TABLE $DB.t_bad2(time TIMESTAMP TIME, dev STRING TAG, s1 DOUBLE FIELD) SECURITY POLICY lb_nopolicy")
  assert_err "$o" "" "绑定不存在策略报错"
}

case_LB100() {
  obj_env
  mk_table
  assert_ok "$(Q "ALTER TABLE $DB.t1 ADD SECURITY POLICY lb_p")" "ADD SECURITY POLICY 成功"
  assert_contains "$(Q "SELECT table_name, security_policy FROM information_schema.tables" | grep -E '\| *t1 *\|')" "lb_p" "策略绑定已记录"
}

case_LB101() {
  obj_env
  mk_table
  Q "ALTER TABLE $DB.t1 ADD SECURITY POLICY lb_p" >/dev/null 2>&1
  assert_err "$(Q "ALTER TABLE $DB.t1 ADD SECURITY POLICY lb_p")" "" "重复绑定策略报错"
}

case_LB102() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  local u; u=$(mk_user c102)
  Q "GRANT ALTER ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  # u 没有 sec 标签写凭证
  assert_err "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH sec")" "2400" "无写凭证新增列保护被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH sec")" "有写凭证后新增列保护成功"
}

case_LB103() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 int
  local u; u=$(mk_user c103)
  Q "GRANT ALTER ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  # 只有 new WRITE（sec），没有 old（int）读写 → 拒绝
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH sec")" "2400" "缺旧标签读写凭证时修改标签被拒"
}

case_LB104() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_rd COMPONENT lb_dept 'RD'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_rdqa COMPONENT lb_dept 'RD','QA'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 l_rd
  local u r
  u=$(mk_user c104); r=$(mk_role c104)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT ALTER ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  # 用户持旧标签 ALL；角色持新标签 WRITE；策略开启 USE ROLE AUTHORIZATIONS 后合并
  Q "GRANT SECURITY LABEL lb_p.l_rd TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l_rdqa TO ROLE $r FOR WRITE ACCESS" >/dev/null 2>&1
  Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  local o
  o=$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH l_rdqa")
  assert_ok "$o" "凭证齐全（旧标签用户 + 新标签角色合并）时修改标签成功"
  assert_contains "$(Q "SELECT column_name, security_label FROM information_schema.columns" | grep -E '\| *s1 *\|')" "l_rdqa" "列标签已更新为 l_rdqa"
}

case_LB105() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  local u; u=$(mk_user c105)
  Q "GRANT ALTER ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 SECURED WITH sec")" "相同标签幂等成功"
}

case_LB106() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  local u; u=$(mk_user c106)
  Q "GRANT ALTER ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 DROP COLUMN SECURITY")" "2400" "无读写凭证解除列保护被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "ALTER TABLE $DB.t1 ALTER COLUMN s1 DROP COLUMN SECURITY")" "有读写凭证解除成功"
}

case_LB107() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  protect t1 s2 int
  local o
  if [ "${SEP:-0}" = "1" ]; then
    # 三权分立：该操作需要 ALTER(sys) + SECURITY(security)，由 security_admin 自授 ALTER 后执行
    QS "GRANT ALTER ON DATABASE $DB TO USER ${SEC_ADMIN}" >/dev/null 2>&1
    sleep 2
    o=$(L "$SEC_ADMIN" "$ADMIN_PW" "ALTER TABLE $DB.t1 DROP SECURITY POLICY")
  else
    o=$(Q "ALTER TABLE $DB.t1 DROP SECURITY POLICY")
  fi
  assert_ok "$o" "DROP SECURITY POLICY 成功（解除表策略与全部列标签）"
  local lbl
  lbl=$(Q "SELECT column_name, security_label FROM information_schema.columns" | grep -E '\| *(s1|s2) *\|' || true)
  echo "$lbl" | grep -qE 'sec|int' && fail "列标签未清除" || ok "列标签已全部清除"
  # 保护已解除：无凭证用户可读
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c107)
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "解除策略后无凭证用户可读"
}

case_LB108() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  # 可写视图（语法要求最后一级为 **，源为树模型）
  T "CREATE DATABASE IF NOT EXISTS root.${DB}_v" >/dev/null 2>&1
  T "CREATE TIMESERIES root.${DB}_v.dev1.s1 DOUBLE" >/dev/null 2>&1
  Q "CREATE VIEW $DB.wv(dev STRING TAG, s1 DOUBLE FIELD) AS root.${DB}_v.**" >/dev/null 2>&1
  local o1 o2
  o1=$(Q "ALTER TABLE $DB.wv ALTER COLUMN s1 SECURED WITH sec")
  assert_err "$o1" "" "可写视图不能设置列保护"
  # 逻辑视图
  with_label sec "CREATE VIEW $DB.lv AS SELECT * FROM $DB.t1" >/dev/null 2>&1
  o2=$(Q "ALTER TABLE $DB.lv ADD SECURITY POLICY lb_p")
  assert_err "$o2" "" "逻辑视图不能绑定策略"
}

case_LB109() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  with_label sec "CREATE VIEW $DB.wv(dev STRING TAG, s1 DOUBLE FIELD) AS root.${DB}_v.**" >/dev/null 2>&1
  local u; u=$(mk_user c109)
  Q "GRANT SELECT ON TABLE $DB.wv TO USER $u" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.wv")" "2400" "可写视图读：底层表检查生效"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.wv")" "有凭证后经可写视图可读"
}

case_LB110() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  with_label sec "CREATE VIEW $DB.lv AS SELECT * FROM $DB.t1" >/dev/null 2>&1
  local u; u=$(mk_user c110)
  Q "GRANT SELECT ON TABLE $DB.lv TO USER $u" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.lv")" "2400" "逻辑视图查询：底层表检查生效"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.lv")" "有凭证后经逻辑视图可读"
}
