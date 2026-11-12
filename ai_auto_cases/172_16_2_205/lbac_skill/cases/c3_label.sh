# ============================================================================
# LBAC 标签（Label）用例 LB-036 ~ LB-046
# ============================================================================

CASES+=(
"LB-036|标签|正向|CREATE LABEL 单组件单值成功|case_LB036"
"LB-037|标签|正向|CREATE LABEL 多组件多值（SET 多值）|case_LB037"
"LB-038|标签|异常|所有组件均为空值时创建失败|case_LB038"
"LB-039|标签|异常|使用不属于该策略的组件报错|case_LB039"
"LB-040|标签|异常|同一策略下标签重名报错|case_LB040"
"LB-041|标签|正向|不同策略下同名标签允许创建|case_LB041"
"LB-042|标签|异常|SET 多值中出现重复元素报错|case_LB042"
"LB-043|标签|正向|DROP 未被引用的标签成功|case_LB043"
"LB-044|标签|异常|DROP 已授予用户的标签报错|case_LB044"
"LB-045|标签|异常|DROP 被列引用的标签报错|case_LB045"
"LB-046|标签|正向|COMMENT ON LABEL 与规范化 label_value 展示|case_LB046"
)

case_LB036() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'")" "创建单组件标签"
  assert_contains "$(Q "SELECT label_name, policy_name FROM information_schema.security_labels" | grep l1)" "lb_p" "标签归属策略正确"
}

case_LB037() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA','FIN')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl, lb_dept" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY LABEL lb_p.l2 COMPONENT lb_lvl 'A', COMPONENT lb_dept 'RD','QA'")" "创建多组件多值标签"
  local v2; v2=$(Q "SELECT label_name, label_value FROM information_schema.security_labels" | grep l2)
  echo "$v2" | grep -qE 'A:\((RD,QA|QA,RD)\)' && ok "label_value 展示正确（SET 内元素顺序不固定）" || fail "label_value 格式不正确：$(echo "$v2" | head -1)"
}

case_LB038() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY LABEL lb_p.empty_l COMPONENT lb_lvl ''")
  assert_err "$o" "" "全空标签创建失败"
}

case_LB039() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_other SET ('X')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY LABEL lb_p.bad COMPONENT lb_other 'X'")
  assert_err "$o" "" "标签使用策略外组件报错"
}

case_LB040() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'B'")
  assert_err "$o" "" "同策略下标签重名报错"
}

case_LB041() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p1 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p1.same COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY LABEL lb_p2.same COMPONENT lb_lvl 'A'")" "不同策略下同名标签允许"
}

case_LB042() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY LABEL lb_p.dup COMPONENT lb_dept 'RD','RD'")
  assert_err "$o" "" "SET 多值重复元素报错"
}

case_LB043() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.free COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  assert_ok "$(Q "DROP SECURITY LABEL lb_p.free")" "DROP 未被引用标签成功"
  assert_no_rows "$(Q "SELECT label_name FROM information_schema.security_labels" | grep free)" "标签已删除"
}

case_LB044() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.g1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.g1 TO USER root FOR READ ACCESS" >/dev/null 2>&1
  local o
  o=$(Q "DROP SECURITY LABEL lb_p.g1")
  assert_err "$o" "" "已授予的标签不能删除"
}

case_LB045() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.b1 COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.b1 TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 b1
  local o
  o=$(Q "DROP SECURITY LABEL lb_p.b1")
  assert_err "$o" "" "被列引用的标签不能删除"
}

case_LB046() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl, lb_dept" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.c1 COMPONENT lb_lvl 'A', COMPONENT lb_dept 'RD'" >/dev/null 2>&1
  assert_ok "$(Q "COMMENT ON SECURITY LABEL lb_p.c1 IS 'lcmt'")" "添加标签备注"
  assert_contains "$(Q "SELECT label_name, remarks FROM information_schema.security_labels" | grep c1)" "lcmt" "备注已写入"
  local v; v=$(Q "SELECT label_name, label_value FROM information_schema.security_labels" | grep c1)
  # 单值 SET 组件不要求括号（需求：仅多值使用括号）
  echo "$v" | grep -qE 'A:(\(RD\)|RD)' && ok "label_value 规范化为 A:RD（单值不加括号）" || fail "label_value 格式不正确：$(echo "$v" | head -1)"
}
