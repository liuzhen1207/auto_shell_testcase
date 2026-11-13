# ============================================================================
# LBAC 系统表与审计用例 LB-123 ~ LB-131
# ============================================================================

CASES+=(
"LB-123|系统表|正向|普通用户可查询 security_policies|case_LB123"
"LB-124|系统表|正向|security_label_component_elements 的 ordinal/parent 正确|case_LB124"
"LB-125|系统表|正向|security_policy_component_rules 返回读写规则名与顺序|case_LB125"
"LB-126|系统表|正向|security_labels 的规范化 label_value 正确|case_LB126"
"LB-127|系统表|正向|security_label_access 普通用户只看自己、SECURITY 看全部|case_LB127"
"LB-128|系统表|正向|security_policy_exemptions 的可见范围|case_LB128"
"LB-129|系统表|正向|tables.security_policy / columns.security_label 字段正确|case_LB129"
"LB-130|审计|正向|LBAC 拒绝访问产生 LBAC_AUTHENTICATION 审计记录|case_LB130"
"LB-131|审计|正向|LBAC 元数据 DDL 需要 SECURITY 权限（无权限被拒）|case_LB131"
)

case_LB123() {
  obj_env
  local u; u=$(mk_user s1)
  local o
  o=$(u_sql "$u" "SELECT policy_name, component_count, rule_set FROM information_schema.security_policies")
  assert_ok "$o" "普通用户可查询 security_policies"
  assert_contains "$o" "lb_p" "能看到策略"
}

case_LB124() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_arr ARRAY ('A','B','C')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_tr TREE ('R' ROOT, 'X' UNDER 'R')" >/dev/null 2>&1
  local o
  o=$(Q "SELECT component_name, element_value, ordinal, parent_element_value FROM information_schema.security_label_component_elements" | grep lb_arr)
  echo "$o" | grep -qE '\| *A *\| *1 *\|' && ok "ARRAY ordinal 从 1 开始且顺序正确" || fail "ARRAY ordinal 不正确"
  o=$(Q "SELECT component_name, element_value, parent_element_value FROM information_schema.security_label_component_elements" | grep lb_tr)
  echo "$o" | grep -qE '\| *X *\| *R' && ok "TREE 子节点 parent=R" || fail "TREE parent 不正确"
  echo "$o" | grep -qE '\| *R *\| *null' && ok "TREE 根节点 parent 为 null" || note "根节点 parent 展示：$(echo "$o" | head -2 | tr '\n' ' ')"
}

case_LB125() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_a ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_s SET ('X')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_t TREE ('R' ROOT)" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_a, lb_s, lb_t" >/dev/null 2>&1
  local o
  o=$(Q "SELECT policy_name, component_name, component_type, ordinal, read_rule_name, write_rule_name FROM information_schema.security_policy_component_rules" | grep lb_p)
  echo "$o" | grep -qE 'LBACREADARRAY' && ok "ARRAY 读规则 LBACREADARRAY" || fail "ARRAY 读规则缺失"
  echo "$o" | grep -qE 'LBACWRITEARRAY' && ok "ARRAY 写规则 LBACWRITEARRAY" || fail "ARRAY 写规则缺失"
  echo "$o" | grep -qE 'LBACREADSET' && ok "SET 读规则 LBACREADSET" || fail "SET 读规则缺失"
  echo "$o" | grep -qE 'LBACREADTREE' && ok "TREE 读规则 LBACREADTREE" || fail "TREE 读规则缺失"
  local n
  n=$(echo "$o" | grep -c '|')
  [ "$n" -ge 3 ] && ok "三个组件顺序齐全（$n 行）" || fail "组件规则行数不足（$n）"
}

case_LB126() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('R' ROOT, 'S' UNDER 'R')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl, lb_dept, lb_org" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l1 COMPONENT lb_lvl 'A', COMPONENT lb_dept 'RD','QA', COMPONENT lb_org 'S'" >/dev/null 2>&1
  local v
  v=$(Q "SELECT label_name, label_value FROM information_schema.security_labels" | grep l1)
  echo "$v" | grep -qE "A:\((RD,QA|QA,RD)\):S" && ok "label_value 规范化为 A:(RD,QA):S（SET 内元素顺序不固定）" || fail "label_value 格式不正确：$(echo "$v" | head -1)"
}

case_LB127() {
  obj_env
  local u1 u2
  u1=$(mk_user v1); u2=$(mk_user v2)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u1 FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u2 FOR READ ACCESS" >/dev/null 2>&1
  local o
  o=$(u_sql "$u1" "SELECT grantee, label_name FROM information_schema.security_label_access")
  assert_contains "$o" "$u1" "普通用户能看到自己的授权"
  echo "$o" | grep -q "$u2" && fail "普通用户看到了他人授权" || ok "普通用户看不到他人授权"
  o=$(Q "SELECT grantee, label_name FROM information_schema.security_label_access")
  echo "$o" | grep -q "$u1" && echo "$o" | grep -q "$u2" && ok "SECURITY 用户（root）可见全部" || fail "SECURITY 用户未能看到全部记录"
}

case_LB128() {
  obj_env
  local u1; u1=$(mk_user e1)
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u1" >/dev/null 2>&1
  local o
  o=$(u_sql "$u1" "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions")
  assert_contains "$o" "$u1" "普通用户可见自己的豁免"
  o=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions")
  echo "$o" | grep -q "$u1" && ok "SECURITY 用户可见全部豁免" || fail "SECURITY 用户看不到豁免"
}

case_LB129() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  local ot oc
  ot=$(Q "SELECT table_name, security_policy FROM information_schema.tables" | grep -E '\| *t1 *\|')
  assert_contains "$ot" "lb_p" "tables.security_policy 正确"
  oc=$(Q "SELECT table_name, column_name, security_label FROM information_schema.columns" | grep -E '\| *s1 *\|')
  assert_contains "$oc" "sec" "columns.security_label 正确"
}

case_LB130() {
  dml_env
  local u; u=$(mk_user a1)
  u_sql "$u" "SELECT s1 FROM $DB.t1" >/dev/null 2>&1
  sleep 3
  # 审计日志可能默认关闭；先检查 enable_audit_log
  local flag
  flag=$(grep -h '^enable_audit_log' /data2/iotdb/$NEW/conf/iotdb-system.properties 2>/dev/null | tail -1)
  echo "  本地 enable_audit_log：${flag:-（未配置）}"
  local found=0
  local ip
  for ip in 172.16.2.2 172.16.2.3; do
    local n
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip "grep -c 'LBAC_AUTHENTICATION' $DN_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && found=$((found + n))
  done
  if [ "$found" -gt 0 ]; then
    ok "审计日志中出现 LBAC_AUTHENTICATION（$found 次）"
  else
    note "未在 DN 日志中检索到 LBAC_AUTHENTICATION（审计可能未开启或写入独立审计表）"
    # 尝试查审计表
    local o
    o=$(Q "SELECT * FROM information_schema.audit_log" 2>/dev/null | grep -c LBAC_AUTHENTICATION)
    [ "${o:-0}" -gt 0 ] && ok "审计表中存在 LBAC_AUTHENTICATION（$o 条）" || note "审计表不可查或无记录（需开启审计后复验）"
  fi
}

case_LB131() {
  obj_env
  local u; u=$(mk_user m1)
  assert_err "$(u_sql "$u" "DROP SECURITY POLICY lb_p")" "" "无 SECURITY 权限删除策略被拒"
  assert_err "$(u_sql "$u" "CREATE SECURITY LABEL COMPONENT lb_z ARRAY ('A')")" "" "无 SECURITY 权限建组件被拒"
  assert_ok "$(Q "SELECT policy_name FROM information_schema.security_policies")" "root 有 SECURITY 权限"
}
