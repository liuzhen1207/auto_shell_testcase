# ============================================================================
# LBAC 策略（Policy）用例 LB-021 ~ LB-035
# ============================================================================

CASES+=(
"LB-021|策略|正向|CREATE POLICY 单组件成功|case_LB021"
"LB-022|策略|正向|多组件策略的组件顺序决定标签值展示顺序|case_LB022"
"LB-023|策略|异常|引用不存在的组件报错|case_LB023"
"LB-024|策略|异常|策略重名报错|case_LB024"
"LB-025|策略|正向|WITH LBACRULES 与省略等价（rule_set=LBACRULES）|case_LB025"
"LB-026|策略|正向|ALTER ADD COMPONENT 追加到末尾且已有标签补空值|case_LB026"
"LB-027|策略|异常|ALTER ADD 重复组件报错|case_LB027"
"LB-028|策略|正向|ALTER ADD 多个组件（多条子句）|case_LB028"
"LB-029|策略|异常|表已绑定策略时 ALTER ADD COMPONENT 报错|case_LB029"
"LB-030|策略|正向|USE/IGNORE ROLE AUTHORIZATIONS 状态切换|case_LB030"
"LB-031|策略|正向|DROP 无依赖策略成功|case_LB031"
"LB-032|策略|异常|DROP 仍有标签的策略报错（2413）|case_LB032"
"LB-033|策略|异常|DROP 被表绑定的策略报错|case_LB033"
"LB-034|策略|异常|DROP 仍有标签授权/免除权的策略报错|case_LB034"
"LB-035|策略|正向|COMMENT ON POLICY 添加与替换备注|case_LB035"
)

case_LB021() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl")" "创建单组件策略"
  local o
  o=$(Q "SELECT policy_name, component_count, rule_set, role_authorizations FROM information_schema.security_policies")
  assert_contains "$o" "lb_p" "策略可见"
  echo "$o" | grep -qE '\| *lb_p *\| *1 *\|' && ok "component_count=1" || fail "component_count 不为 1"
  echo "$o" | grep -qE 'IGNORED' && ok "默认 IGNORE ROLE AUTHORIZATIONS" || fail "默认角色授权状态不正确"
}

case_LB022() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl, lb_dept")" "创建双组件策略"
  local o
  o=$(Q "SELECT policy_name, component_name, ordinal FROM information_schema.security_policy_component_rules" | grep lb_p)
  echo "$o" | grep -qE 'lb_lvl *\| *1' && ok "lb_lvl ordinal=1" || fail "lb_lvl 顺序不是 1"
  echo "$o" | grep -qE 'lb_dept *\| *2' && ok "lb_dept ordinal=2" || fail "lb_dept 顺序不是 2"
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A', COMPONENT lb_dept 'RD','QA'" >/dev/null 2>&1
  local v
  v=$(Q "SELECT label_name, label_value FROM information_schema.security_labels" | grep l1)
  echo "$v" | grep -qE 'A:\((RD,QA|QA,RD)\)' && ok "标签值按组件顺序展示（SET 内元素顺序不固定）" || fail "label_value 格式不正确：$(echo "$v" | head -1)"
}

case_LB023() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY POLICY lb_p_bad COMPONENTS lb_no_such")
  assert_err "$o" "" "引用不存在组件报错"
}

case_LB024() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl")
  assert_err "$o" "" "策略重名报错"
}

case_LB025() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p1 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl WITH LBACRULES" >/dev/null 2>&1
  local o
  o=$(Q "SELECT policy_name, rule_set FROM information_schema.security_policies" | grep -E 'lb_p1|lb_p2')
  echo "$o" | grep -c "LBACRULES" | grep -q "^2$" && ok "两种写法 rule_set 均为 LBACRULES" || fail "rule_set 不一致：$(echo "$o" | tr '\n' ' ')"
}

case_LB026() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p ADD SECURITY LABEL COMPONENT lb_dept")" "追加组件"
  local o
  o=$(Q "SELECT policy_name, component_name, ordinal FROM information_schema.security_policy_component_rules" | grep lb_p)
  echo "$o" | grep -qE 'lb_dept *\| *2' && ok "新组件追加到末尾（ordinal=2）" || fail "新组件未追加到末尾"
  local v
  v=$(Q "SELECT label_name, label_value FROM information_schema.security_labels" | grep l1)
  assert_contains "$v" "A:()" "已有标签自动补空值 A:()"
}

case_LB027() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local o
  o=$(Q "ALTER SECURITY POLICY lb_p ADD SECURITY LABEL COMPONENT lb_lvl")
  assert_err "$o" "" "重复追加同组件报错"
}

case_LB028() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c1 ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_c2 SET ('RD')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_c3 SET ('X')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_c1" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p ADD SECURITY LABEL COMPONENT lb_c2 ADD SECURITY LABEL COMPONENT lb_c3")" "一次追加两个组件"
  local o
  o=$(Q "SELECT component_name, ordinal FROM information_schema.security_policy_component_rules" | grep -E 'lb_c2|lb_c3')
  echo "$o" | grep -qE 'lb_c2 *\| *2' && ok "lb_c2 ordinal=2" || fail "lb_c2 顺序错误"
  echo "$o" | grep -qE 'lb_c3 *\| *3' && ok "lb_c3 ordinal=3" || fail "lb_c3 顺序错误"
}

case_LB029() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l1 TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  local o
  o=$(Q "ALTER SECURITY POLICY lb_p ADD SECURITY LABEL COMPONENT lb_dept")
  assert_err "$o" "" "表已绑定该策略时追加组件报错"
}

case_LB030() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS")" "USE ROLE AUTHORIZATIONS"
  assert_contains "$(Q "SELECT policy_name, role_authorizations FROM information_schema.security_policies" | grep lb_p)" "USED" "状态为 USED"
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p IGNORE ROLE AUTHORIZATIONS")" "IGNORE ROLE AUTHORIZATIONS"
  assert_contains "$(Q "SELECT policy_name, role_authorizations FROM information_schema.security_policies" | grep lb_p)" "IGNORED" "状态为 IGNORED"
}

case_LB031() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  assert_ok "$(Q "DROP SECURITY POLICY lb_p")" "DROP 无依赖策略成功"
  assert_no_rows "$(Q "SELECT policy_name FROM information_schema.security_policies" | grep lb_p)" "策略已删除"
}

case_LB032() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  local o
  o=$(Q "DROP SECURITY POLICY lb_p")
  assert_err "$o" "2413" "仍有标签时 DROP 策略报错（2413）"
}

case_LB033() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l1 TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  local o
  o=$(Q "DROP SECURITY POLICY lb_p")
  assert_err "$o" "" "被表绑定时 DROP 策略报错"
}

case_LB034() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  # 授予豁免权（不授予 label），验证豁免也阻止删除
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER root" >/dev/null 2>&1
  local o
  o=$(Q "DROP SECURITY POLICY lb_p")
  assert_err "$o" "" "存在豁免权时 DROP 策略报错"
  # 撤销豁免 + 删 label 后应可删
  Q "REVOKE EXEMPTION ON RULE LBACREADARRAY FOR lb_p FROM USER root" >/dev/null 2>&1
  Q "DROP SECURITY LABEL lb_p.l1" >/dev/null 2>&1
  assert_ok "$(Q "DROP SECURITY POLICY lb_p")" "清理依赖后 DROP 策略成功"
}

case_LB035() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  assert_ok "$(Q "COMMENT ON SECURITY POLICY lb_p IS 'p1'")" "添加策略备注"
  assert_contains "$(Q "SELECT policy_name, remarks FROM information_schema.security_policies" | grep lb_p)" "p1" "备注已写入"
  assert_ok "$(Q "COMMENT ON SECURITY POLICY lb_p IS 'p2'")" "替换策略备注"
  assert_contains "$(Q "SELECT policy_name, remarks FROM information_schema.security_policies" | grep lb_p)" "p2" "备注已替换"
}
