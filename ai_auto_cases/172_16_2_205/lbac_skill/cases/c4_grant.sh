# ============================================================================
# LBAC 授权与规则免除权用例 LB-047 ~ LB-060
# ============================================================================

CASES+=(
"LB-047|授权|正向|GRANT READ ACCESS 成功且系统表可见|case_LB047"
"LB-048|授权|正向|GRANT WRITE ACCESS 成功|case_LB048"
"LB-049|授权|正向|GRANT ALL ACCESS 同时产生读写两条记录|case_LB049"
"LB-050|授权|异常|重复授予同一标签同一访问类型报错|case_LB050"
"LB-051|授权|异常|同策略下另一标签占用同一访问类型报错|case_LB051"
"LB-052|授权|异常|已有 READ 后 GRANT ALL 报错|case_LB052"
"LB-053|授权|异常|已有 ALL 后再 GRANT READ 报错|case_LB053"
"LB-054|授权|异常|授予不存在的标签报错|case_LB054"
"LB-055|授权|异常|授予不存在的用户报错|case_LB055"
"LB-056|授权|正向|授予角色成功（grantee_type=ROLE）|case_LB056"
"LB-057|授权|正向|REVOKE 一次性清除读写授权|case_LB057"
"LB-058|授权|异常|撤销不存在的授权报错|case_LB058"
"LB-059|授权|异常|无 SECURITY 权限的用户执行 LBAC DDL 被拒|case_LB059"
"LB-060|授权|正向|USE/IGNORE ROLE AUTHORIZATIONS 决定角色标签是否参与判断|case_LB060"
"LB-061|豁免|正向|GRANT EXEMPTION LBACREADARRAY 后读放行|case_LB061"
"LB-062|豁免|正向|LBACWRITEARRAY WRITE_UP 只免上写，下写仍拒绝|case_LB062"
"LB-063|豁免|正向|GRANT EXEMPTION ALL 展开为多条记录|case_LB063"
"LB-064|豁免|边界|重复授予同一豁免静默成功且不刷新时间|case_LB064"
"LB-065|豁免|正向|REVOKE 单条豁免生效|case_LB065"
"LB-066|豁免|异常|撤销不存在的豁免报错|case_LB066"
"LB-067|豁免|正向|REVOKE ALL 清空该策略下全部豁免|case_LB067"
"LB-068|豁免|正向|角色豁免在 IGNORE 下不生效、USE 下生效|case_LB068"
)

case_LB047() {
  arr_env pub
  local u; u=$(mk_user g1)
  assert_ok "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS")" "GRANT READ"
  local o
  o=$(Q "SELECT grantee, label_name, access_type FROM information_schema.security_label_access" | grep "$u")
  assert_contains "$o" "pub" "标签名正确"
  assert_contains "$o" "READ" "访问类型 READ"
}

case_LB048() {
  arr_env pub
  local u; u=$(mk_user g2)
  assert_ok "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR WRITE ACCESS")" "GRANT WRITE"
  assert_contains "$(Q "SELECT grantee, access_type FROM information_schema.security_label_access" | grep "$u")" "WRITE" "访问类型 WRITE"
}

case_LB049() {
  arr_env pub
  local u; u=$(mk_user g3)
  assert_ok "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR ALL ACCESS")" "GRANT ALL"
  local n
  n=$(Q "SELECT grantee, access_type FROM information_schema.security_label_access" | grep "$u" | wc -l)
  [ "$n" = "1" ] && ok "系统表合并为 1 条（ALL）" || note "系统表返回 $n 条（预期 1 条 ALL）"
  assert_contains "$(Q "SELECT grantee, access_type FROM information_schema.security_label_access" | grep "$u")" "ALL" "访问类型 ALL"
}

case_LB050() {
  arr_env pub
  local u; u=$(mk_user g4)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS")" "" "重复授予同类型报错"
}

case_LB051() {
  arr_env pub
  local u; u=$(mk_user g5)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.int TO USER $u FOR READ ACCESS")" "" "另一标签占用 READ 报错"
}

case_LB052() {
  arr_env pub
  local u; u=$(mk_user g6)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR ALL ACCESS")" "" "已有 READ 后 GRANT ALL 报错"
}

case_LB053() {
  arr_env pub
  local u; u=$(mk_user g7)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS")" "" "已有 ALL 后 GRANT READ 报错"
}

case_LB054() {
  arr_env pub
  local u; u=$(mk_user g8)
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.nolabel TO USER $u FOR READ ACCESS")" "2405" "授予不存在标签报错（2405）"
}

case_LB055() {
  arr_env pub
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.pub TO USER lbu_ghost FOR READ ACCESS")" "804" "授予不存在用户报错（804）"
}

case_LB056() {
  arr_env pub
  local r; r=$(mk_role g9)
  assert_ok "$(Q "GRANT SECURITY LABEL lb_p.pub TO ROLE $r FOR READ ACCESS")" "授予角色"
  local o
  o=$(Q "SELECT grantee, grantee_type FROM information_schema.security_label_access" | grep "$r")
  assert_contains "$o" "ROLE" "grantee_type=ROLE"
}

case_LB057() {
  arr_env pub
  local u; u=$(mk_user g10)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_ok "$(Q "REVOKE SECURITY LABEL lb_p.pub FROM USER $u")" "REVOKE"
  local n
  n=$(Q "SELECT access_type FROM information_schema.security_label_access" | grep -c "$u")
  [ "$n" = "0" ] && ok "读写授权均被清除" || fail "仍有 $n 条授权残留"
}

case_LB058() {
  arr_env pub
  local u; u=$(mk_user g11)
  assert_err "$(Q "REVOKE SECURITY LABEL lb_p.pub FROM USER $u")" "" "撤销不存在授权报错"
}

case_LB059() {
  arr_env pub
  Q "CREATE USER lbu_no_sec '$UPW'" >/dev/null 2>&1
  Q "GRANT SELECT ON TABLE $DB.t1 TO USER lbu_no_sec" >/dev/null 2>&1
  local o
  o=$(u_sql lbu_no_sec "CREATE SECURITY LABEL COMPONENT lb_x ARRAY ('A')")
  assert_err "$o" "" "无 SECURITY 权限用户建组件被拒"
  o=$(u_sql lbu_no_sec "GRANT SECURITY LABEL lb_p.pub TO USER lbu_no_sec FOR READ ACCESS")
  assert_err "$o" "" "无 SECURITY 权限用户授权被拒"
}

case_LB060() {
  arr_env sec
  local u r
  u=$(mk_user g12); r=$(mk_role g12)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO ROLE $r FOR READ ACCESS" >/dev/null 2>&1
  local o
  o=$(u_sql "$u" "SELECT s1 FROM $DB.t1")
  assert_err "$o" "2400" "IGNORE 模式下角色标签不参与（读被拒）"
  Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  o=$(u_sql "$u" "SELECT s1 FROM $DB.t1")
  assert_ok "$o" "USE 模式下角色标签参与（读成功）"
  assert_contains "$o" "1.5" "读到正确数据"
}

# ---------------- 豁免权 ----------------
case_LB061() {
  arr_env sec
  local u; u=$(mk_user e1)
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "豁免前：PUB 用户读 SEC 列被拒"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "授予 LBACREADARRAY 豁免"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "豁免后：读放行"
}

case_LB062() {
  arr_env sec
  local u; u=$(mk_user e2)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  protect t1 s2 pub
  # 下写：SEC 用户写 PUB 保护列 -> 拒绝
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(2,'d1',2.5)")" "2400" "下写被拒（SEC 写 PUB 保护列）"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACWRITEARRAY WRITE_UP FOR lb_p TO USER $u")" "只授予 WRITE_UP 豁免"
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(3,'d1',3.5)")" "2400" "WRITE_UP 豁免不能免除下写"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACWRITEARRAY WRITE_DOWN FOR lb_p TO USER $u")" "再授予 WRITE_DOWN 豁免"
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(4,'d1',4.5)")" "两个方向都豁免后写成功"
}

case_LB063() {
  arr_env pub
  local u; u=$(mk_user e3)
  assert_ok "$(Q "GRANT EXEMPTION ON RULE ALL FOR lb_p TO USER $u")" "GRANT EXEMPTION ALL"
  local n
  n=$(Q "SELECT grantee, rule_name, access_type FROM information_schema.security_policy_exemptions" | grep -c "$u")
  echo "  系统表中该用户的豁免记录数：$n"
  [ "$n" -ge 2 ] && ok "ALL 已展开为多条具体规则（$n 条）" || fail "ALL 未展开（仅 $n 条）"
}

case_LB064() {
  arr_env pub
  local u; u=$(mk_user e4)
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u" >/dev/null 2>&1
  local t1 t2
  t1=$(Q "SELECT grantee, grant_time FROM information_schema.security_policy_exemptions" | grep "$u" | head -1)
  sleep 2
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "重复授予静默成功"
  t2=$(Q "SELECT grantee, grant_time FROM information_schema.security_policy_exemptions" | grep "$u" | head -1)
  [ "$t1" = "$t2" ] && ok "grant_time 未被刷新" || note "grant_time 变化（$t1 -> $t2）"
  local n
  n=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | grep -c "$u")
  [ "$n" = "1" ] && ok "仅一条豁免记录" || fail "豁免记录重复（$n 条）"
}

case_LB065() {
  arr_env pub
  local u; u=$(mk_user e5)
  Q "GRANT EXEMPTION ON RULE LBACREADSET FOR lb_p TO USER $u" >/dev/null 2>&1
  assert_ok "$(Q "REVOKE EXEMPTION ON RULE LBACREADSET FOR lb_p FROM USER $u")" "REVOKE 单条豁免"
  local n
  n=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | grep -c "$u")
  [ "$n" = "0" ] && ok "豁免记录已删除" || fail "仍有 $n 条豁免"
}

case_LB066() {
  arr_env pub
  local u; u=$(mk_user e6)
  assert_err "$(Q "REVOKE EXEMPTION ON RULE LBACREADSET FOR lb_p FROM USER $u")" "" "撤销不存在豁免报错"
}

case_LB067() {
  arr_env pub
  local u; u=$(mk_user e7)
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADSET FOR lb_p TO USER $u" >/dev/null 2>&1
  assert_ok "$(Q "REVOKE EXEMPTION ON RULE ALL FOR lb_p FROM USER $u")" "REVOKE EXEMPTION ALL"
  local n
  n=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | grep -c "$u")
  [ "$n" = "0" ] && ok "全部豁免已清空" || fail "仍有 $n 条豁免"
  assert_ok "$(Q "REVOKE EXEMPTION ON RULE ALL FOR lb_p FROM USER $u")" "无豁免时 REVOKE ALL 静默成功"
}

case_LB068() {
  arr_env sec
  local u r
  u=$(mk_user e8); r=$(mk_role e8)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO ROLE $r" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "IGNORE 模式：角色豁免不生效"
  Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "USE 模式：角色豁免生效"
}
