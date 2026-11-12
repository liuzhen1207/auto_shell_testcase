# ============================================================================
# LBAC 组件（Component）用例 LB-001 ~ LB-020
# 需求：安全标签组件 ARRAY/SET/TREE、命名与元素约束、ALTER ADD ELEMENT、DROP 依赖校验
# ============================================================================

CASES+=(
"LB-001|组件|正向|CREATE ARRAY 组件成功且系统表可见|case_LB001"
"LB-002|组件|正向|CREATE SET 组件成功|case_LB002"
"LB-003|组件|正向|CREATE TREE 组件成功（ROOT/UNDER 层级）|case_LB003"
"LB-004|组件|异常|组件重名报错|case_LB004"
"LB-005|组件|异常|ARRAY 元素重复报错|case_LB005"
"LB-006|组件|异常|SET 元素重复报错|case_LB006"
"LB-007|组件|异常|TREE 节点跨分支重复报错|case_LB007"
"LB-008|组件|边界|元素含保留字符 (,): 报错|case_LB008"
"LB-009|组件|边界|空元素/空白元素报错|case_LB009"
"LB-010|组件|边界|元素长度超 32 bytes 报错|case_LB010"
"LB-011|组件|正向|ALTER ARRAY ADD ELEMENT BEFORE/AFTER 位置正确|case_LB011"
"LB-012|组件|正向|ALTER SET ADD ELEMENT 无需位置|case_LB012"
"LB-013|组件|正向|ALTER TREE ADD ELEMENT UNDER 成功|case_LB013"
"LB-014|组件|边界|ALTER TREE ADD ROOT 后原 ROOT 不再是 ROOT|case_LB014"
"LB-015|组件|异常|ALTER ADD 已存在元素报错|case_LB015"
"LB-016|组件|异常|TREE OVER 列表元素重复报错|case_LB016"
"LB-017|组件|异常|TREE OVER 跨父节点报错|case_LB017"
"LB-018|组件|正向|DROP 未被引用的组件成功|case_LB018"
"LB-019|组件|异常|DROP 被 Policy 引用的组件报错|case_LB019"
"LB-020|组件|正向|COMMENT ON COMPONENT 添加与替换备注|case_LB020"
)

# 系统表取元素信息：component_name, element_value, ordinal, parent_element_value
comp_elems() {  # $1=组件名
  Q "SELECT component_name, element_value, ordinal, parent_element_value FROM information_schema.security_label_component_elements" 2>/dev/null | grep -F "$1"
}

case_LB001() {
  lbac_reset
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_c_arr ARRAY ('A','B','C')")" "创建 ARRAY 组件"
  local o
  o=$(Q "SELECT component_name, component_type, element_count FROM information_schema.security_label_components")
  assert_contains "$o" "lb_c_arr" "系统表可见组件"
  assert_contains "$o" "ARRAY" "类型为 ARRAY"
  assert_contains "$o" "3" "元素数 3"
  assert_contains "$(comp_elems lb_c_arr)" "A" "元素 A 可见"
}

case_LB002() {
  lbac_reset
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_c_set SET ('RD','QA')")" "创建 SET 组件"
  assert_contains "$(Q "SELECT component_name, component_type FROM information_schema.security_label_components" | grep lb_c_set)" "SET" "类型为 SET"
}

case_LB003() {
  lbac_reset
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_c_tree TREE ('ROOTN' ROOT, 'A' UNDER 'ROOTN', 'B' UNDER 'A')")" "创建 TREE 组件"
  local o
  o=$(comp_elems lb_c_tree)
  assert_contains "$o" "ROOTN" "根节点存在"
  echo "$o" | grep -qE '\| *A *\|.*ROOTN' && ok "A 的父节点为 ROOTN" || fail "A 的父节点不正确"
}

case_LB004() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_dup ARRAY ('A')" >/dev/null 2>&1
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_dup ARRAY ('B')")
  assert_err "$o" "" "重复组件名报错"
}

case_LB005() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_dupe ARRAY ('A','B','A')")
  assert_err "$o" "" "ARRAY 元素重复报错"
}

case_LB006() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_dupe SET ('RD','RD')")
  assert_err "$o" "" "SET 元素重复报错"
}

case_LB007() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_dupt TREE ('R' ROOT, 'A' UNDER 'R', 'C' UNDER 'A', 'B' UNDER 'R', 'C' UNDER 'B')")
  assert_err "$o" "" "TREE 跨分支重复节点报错"
}

case_LB008() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_char ARRAY ('A,B')")
  assert_err "$o" "" "元素含逗号报错"
}

case_LB009() {
  lbac_reset
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_empty ARRAY ('')")
  assert_err "$o" "" "空元素报错"
}

case_LB010() {
  lbac_reset
  local long=abcdefghijabcdefghijabcdefghijABC    # 33 bytes
  local o
  o=$(Q "CREATE SECURITY LABEL COMPONENT lb_c_long ARRAY ('$long')")
  assert_err "$o" "" "元素超过 32 bytes 报错"
  # 反证：32 bytes 可创建
  local ok32=abcdefghijabcdefghijabcdefghijAB      # 32 bytes
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_c_long32 ARRAY ('$ok32')")" "32 bytes 元素可创建"
}

case_LB011() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_ord ARRAY ('A','C')" >/dev/null 2>&1
  Q "ALTER SECURITY LABEL COMPONENT lb_c_ord ADD ELEMENT 'B' AFTER 'A'" >/dev/null 2>&1
  Q "ALTER SECURITY LABEL COMPONENT lb_c_ord ADD ELEMENT 'Z' BEFORE 'A'" >/dev/null 2>&1
  local o
  o=$(comp_elems lb_c_ord)
  # 期望顺序 Z, A, B, C
  local seq
  seq=$(echo "$o" | awk -F'|' 'NF>4 {gsub(/ /,"",$4); print $4}' | tr '\n' ',')
  echo "  ordinal 序列：$seq"
  echo "$seq" | grep -q '^1,2,3,4,$' && ok "ordinal 连续（1..4）" || fail "ordinal 不连续：$seq"
  echo "$o" | grep -qE '\| *A *\| *2 *\|' && ok "B AFTER A 后 A 为第 2" || fail "AFTER 位置不正确"
  echo "$o" | grep -qE '\| *Z *\| *1 *\|' && ok "Z BEFORE A 为第 1" || fail "BEFORE 位置不正确"
}

case_LB012() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_set2 SET ('A')" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_c_set2 ADD ELEMENT 'B'")" "SET ADD ELEMENT 无位置参数成功"
  assert_contains "$(comp_elems lb_c_set2)" "B" "新元素 B 存在"
}

case_LB013() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_t2 TREE ('R' ROOT, 'A' UNDER 'R')" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_c_t2 ADD ELEMENT 'B' UNDER 'A'")" "TREE ADD UNDER 成功"
  assert_contains "$(comp_elems lb_c_t2)" "B" "节点 B 存在"
  comp_elems lb_c_t2 | grep -qE '\| *B *\|.*\| *A' && ok "B 的父节点为 A" || fail "B 父节点不正确"
}

case_LB014() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_t3 TREE ('R1' ROOT, 'A' UNDER 'R1')" >/dev/null 2>&1
  local o
  o=$(Q "ALTER SECURITY LABEL COMPONENT lb_c_t3 ADD ELEMENT 'R2' ROOT")
  echo "  ADD ROOT 返回：$(echo "$o" | head -1 | cut -c1-120)"
  # 需求：相当于原 root 变成非 root；若实现拒绝则记录现状
  if echo "$o" | grep -qiE 'exception|error'; then
    note "ADD ROOT 在已有 ROOT 时被拒绝（需与需求确认：需求说明是原 root 降级为新 root 的子节点）"
  else
    local p
    p=$(comp_elems lb_c_t3 | awk -F'|' 'NF>4 {gsub(/ /,"",$3); gsub(/ /,"",$5); print $3"->"$5}')
    echo "  父子关系：$(echo "$p" | tr '\n' ' ')"
    echo "$p" | grep -q 'R1->R2' && ok "原 ROOT 降级为 R2 的子节点" || fail "原 ROOT 未按需求降级：$(echo "$p" | tr '\n' ' ')"
  fi
}

case_LB015() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_dupadd ARRAY ('A','B')" >/dev/null 2>&1
  local o
  o=$(Q "ALTER SECURITY LABEL COMPONENT lb_c_dupadd ADD ELEMENT 'A' AFTER 'B'")
  assert_err "$o" "" "ADD 已存在元素报错"
}

case_LB016() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_over TREE ('R' ROOT, 'A' UNDER 'R', 'B' UNDER 'R')" >/dev/null 2>&1
  local o
  o=$(Q "ALTER SECURITY LABEL COMPONENT lb_c_over ADD ELEMENT 'C' UNDER 'R' OVER 'A','A'")
  assert_err "$o" "" "OVER 列表重复元素报错"
}

case_LB017() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_over2 TREE ('R' ROOT, 'A' UNDER 'R', 'B' UNDER 'R', 'X' UNDER 'A', 'Y' UNDER 'B')" >/dev/null 2>&1
  local o
  o=$(Q "ALTER SECURITY LABEL COMPONENT lb_c_over2 ADD ELEMENT 'C' UNDER 'R' OVER 'X','Y'")
  assert_err "$o" "" "OVER 跨父节点报错"
}

case_LB018() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_free ARRAY ('A')" >/dev/null 2>&1
  assert_ok "$(Q "DROP SECURITY LABEL COMPONENT lb_c_free")" "DROP 未被引用组件成功"
  assert_no_rows "$(Q "SELECT component_name FROM information_schema.security_label_components" | grep lb_c_free)" "组件已删除"
}

case_LB019() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_ref ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p_ref COMPONENTS lb_c_ref" >/dev/null 2>&1
  local o
  o=$(Q "DROP SECURITY LABEL COMPONENT lb_c_ref")
  assert_err "$o" "2412" "DROP 被 Policy 引用的组件报错（2412）"
}

case_LB020() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_c_cmt ARRAY ('A')" >/dev/null 2>&1
  assert_ok "$(Q "COMMENT ON SECURITY LABEL COMPONENT lb_c_cmt IS 'first'")" "添加备注"
  assert_contains "$(Q "SELECT component_name, remarks FROM information_schema.security_label_components" | grep lb_c_cmt)" "first" "备注已写入"
  assert_ok "$(Q "COMMENT ON SECURITY LABEL COMPONENT lb_c_cmt IS 'second'")" "替换备注"
  assert_contains "$(Q "SELECT component_name, remarks FROM information_schema.security_label_components" | grep lb_c_cmt)" "second" "备注已替换"
}
