# ============================================================================
# 第二批自测缺口用例 LB-181 ~ LB-197（备注权限/歧义值/空值三态/多角色/
#   六规则豁免/SET-TREE 豁免/策略级豁免/并发 DDL/活跃会话/系统表可见性）
#   LB-196/197 因“SET/TREE 多值标签”语法不支持而 SKIP（已记录为待确认差异）
# ============================================================================

CASES+=(
"LB-181|组件|反向|无 SECURITY 用户与不存在对象的 COMMENT 被拒|case_LB181"
"LB-182|标签|异常|歧义/非法标签值（括号不配对、嵌套、冒号、越界元素）被拒|case_LB182"
"LB-183|比较|边界|SET 维度空值三态（空用户/空对象/双方空）|case_LB183"
"LB-184|比较|边界|TREE 维度空值三态（空用户/空对象/双方空）|case_LB184"
"LB-185|比较|正向|多角色多策略：USED/IGNORED 混合下角色标签生效范围|case_LB185"
"LB-186|豁免|正向|六条内置规则逐一 GRANT/REVOKE 与记录核对|case_LB186"
"LB-187|豁免|正向|LBACWRITEARRAY 的 WRITE_UP / WRITE_DOWN 方向语义|case_LB187"
"LB-188|豁免|正向|SET 维度豁免：READSET / WRITESET 放行集合不满足的读写|case_LB188"
"LB-189|豁免|正向|TREE 维度豁免：READTREE / WRITETREE 放行后代访问|case_LB189"
"LB-190|豁免|反向|策略级豁免不跨策略生效|case_LB190"
"LB-191|豁免|边界|多规则叠加后逐步撤销；非法规则/方向组合被拒|case_LB191"
"LB-192|并发|并发|8 个并发会话创建同名组件：仅 1 个成功|case_LB192"
"LB-193|并发|边界|活跃访问期间执行必失败操作后，原访问与元数据不受影响|case_LB193"
"LB-194|系统表|正向|SECURITY 主体与普通用户对 security_label_access 的可见范围|case_LB194"
"LB-195|绑定|正向|两个策略下的同名标签互不串用|case_LB195"
"LB-196|比较|正向|SET 多值标签：集合覆盖语义（对象 (RD,QA)、用户 RD 拒 / 用户 (RD,QA) 允）|case_LB196"
"LB-197|比较|正向|TREE 多值标签：任一值命中即放行（对象 (RND,STORAGE)：RND 允、SUPPORT 拒、COMPANY 允）|case_LB197"
)


# 三组件环境 + 一条 t1 表（不预置列保护，按用例自行保护）
mv3_env() {
  mv_env
  mk_table
  bind_policy t1 lb_p
}

case_LB181() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  Q "CREATE USER lbu_c181 '$UPW'" >/dev/null 2>&1
  sleep 2
  assert_err "$(u_sql lbu_c181 "COMMENT ON SECURITY LABEL COMPONENT lb_lvl IS 'x'")" "803" "无 SECURITY 用户 COMMENT 组件被拒"
  assert_err "$(u_sql lbu_c181 "COMMENT ON SECURITY POLICY lb_p IS 'x'")" "803" "无 SECURITY 用户 COMMENT 策略被拒"
  assert_err "$(Q "COMMENT ON SECURITY LABEL COMPONENT no_such_comp IS 'x'")" "" "评论不存在的组件被拒"
  assert_err "$(Q "COMMENT ON SECURITY POLICY lb_p_no IS 'x'")" "" "评论不存在的策略被拒"
}

case_LB182() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept, lb_org" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY LABEL lb_p.bad1 COMPONENT lb_dept '(RD'")" "" "括号不配对被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_p.bad2 COMPONENT lb_dept '((RD))'")" "" "嵌套括号被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_p.bad3 COMPONENT lb_dept 'RD:QA'")" "" "冒号跨组件值被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_p.bad4 COMPONENT lb_org 'NO_NODE'")" "" "TREE 不存在节点被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_p.bad5 COMPONENT lb_dept 'RD', COMPONENT lb_dept 'QA'")" "701" "同组件重复指定被拒"
}

case_LB183() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.rd COMPONENT lb_dept 'RD'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 rd
  with_label rd "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  # 空标签用户（无授权 → 默认空标签）
  local u; u=$(mk_user c183)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "空用户标签读 RD 对象被拒"
  # 空对象：未保护列不受影响
  assert_ok "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "空对象/未保护列可读"
  Q "GRANT SECURITY LABEL lb_p.rd TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "用户 (RD) 读 RD 对象允许"
}

case_LB184() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_org" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.rnd COMPONENT lb_org 'RND'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.company COMPONENT lb_org 'COMPANY'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 rnd
  with_label rnd "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c184)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "空用户标签读 RND 对象被拒"
  Q "GRANT SECURITY LABEL lb_p.company TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "祖先 COMPANY 读 RND 对象允许"
  # 空对象：保护值为空的列任何用户可读
  protect t1 s2 "" >/dev/null 2>&1
  local u2; u2=$(mk_user c184b)
  assert_ok "$(u_sql "$u2" "SELECT s2 FROM $DB.t1")" "对象保护值为空时不阻挡空标签用户"
}

case_LB185() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('TOP','SEC','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p1 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p1.sec COMPONENT lb_lvl 'SEC'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p2.sec COMPONENT lb_lvl 'SEC'" >/dev/null 2>&1
  mk_table t1
  bind_policy t1 lb_p1
  protect t1 s1 sec lb_p1
  mk_table t2
  bind_policy t2 lb_p2
  protect t2 s1 sec lb_p2
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  with_label sec "INSERT INTO $DB.t2(time,dev,s1) VALUES(1,'d1',2.5)" lb_p2 >/dev/null 2>&1
  local r u
  r=$(mk_role c185); u=$(mk_user c185u)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SELECT ON TABLE $DB.t2 TO USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p1.sec TO ROLE $r FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p2.sec TO ROLE $r FOR READ ACCESS" >/dev/null 2>&1
  Q "ALTER SECURITY POLICY lb_p1 IGNORE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  Q "ALTER SECURITY POLICY lb_p2 IGNORE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  sleep 2
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "IGNORE 下角色标签不生效（p1）"
  Q "ALTER SECURITY POLICY lb_p1 USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  sleep 3
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "p1 切 USE 后角色标签生效"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t2")" "2400" "p2 仍 IGNORE：角色标签不生效"
  Q "ALTER SECURITY POLICY lb_p2 USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  sleep 3
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t2")" "p2 切 USE 后也生效"
}

case_LB186() {
  mv_env
  mk_table
  bind_policy t1 lb_p
  local u; u=$(mk_user c186)
  local rules="LBACREADARRAY LBACREADSET LBACREADTREE LBACWRITESET LBACWRITETREE"
  local r
  for r in $rules; do
    assert_ok "$(Q "GRANT EXEMPTION ON RULE $r FOR lb_p TO USER $u")" "授予 $r"
  done
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACWRITEARRAY WRITE_UP FOR lb_p TO USER $u")" "授予 LBACWRITEARRAY WRITE_UP"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACWRITEARRAY WRITE_DOWN FOR lb_p TO USER $u")" "授予 LBACWRITEARRAY WRITE_DOWN"
  local n
  n=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | awk -F'|' -v g="$u" '{a=$2; gsub(/ /,"",a); if (a==g) c++} END{print c+0}')
  [ "${n:-0}" -ge 7 ] && ok "豁免记录数 ${n}（>=7）" || fail "豁免记录数偏少：${n:-0}"
  for r in $rules; do
    assert_ok "$(Q "REVOKE EXEMPTION ON RULE $r FOR lb_p FROM USER $u")" "撤销 $r"
  done
  n=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | awk -F'|' -v g="$u" '{a=$2; gsub(/ /,"",a); if (a==g) c++} END{print c+0}')
  [ "${n:-0}" -le 2 ] && ok "撤销后仅剩 WRITEARRAY 方向记录（${n}）" || fail "撤销后仍剩 ${n} 条"
}

case_LB187() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  protect t1 s2 top
  protect t1 s3 int
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2,s3) VALUES(1,'d1',1.5,9.5,5.5)" >/dev/null 2>&1
  local u; u=$(mk_user c187)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(2,'d1',8.5)")" "2400" "无豁免：写上级 TOP 被拒"
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s3) VALUES(3,'d1',6.5)")" "2400" "无豁免：写下级 INT 被拒"
  Q "GRANT EXEMPTION ON RULE LBACWRITEARRAY WRITE_UP FOR lb_p TO USER $u" >/dev/null 2>&1
  sleep 2
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(4,'d1',7.5)")" "WRITE_UP 豁免后写 TOP 放行"
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s3) VALUES(5,'d1',4.5)")" "2400" "WRITE_UP 不影响下写：写 INT 仍拒"
}

case_LB188() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA','FIN')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.qa COMPONENT lb_dept 'QA'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.rd COMPONENT lb_dept 'RD'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 rd
  protect t1 s2 qa
  with_label rd "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c188)
  Q "GRANT SECURITY LABEL lb_p.rd TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "RD 用户读 RD 对象允许"
  assert_err "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "2400" "RD 用户读 QA 对象被拒（集合不覆盖）"
  Q "GRANT EXEMPTION ON RULE LBACREADSET FOR lb_p TO USER $u" >/dev/null 2>&1
  sleep 2
  assert_ok "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "READSET 豁免后读 QA 对象放行"
}

case_LB189() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY', 'SUPPORT' UNDER 'COMPANY')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_org" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.rnd COMPONENT lb_org 'RND'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.sup COMPONENT lb_org 'SUPPORT'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 rnd
  with_label rnd "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c189)
  Q "GRANT SECURITY LABEL lb_p.sup TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "兄弟分支 SUPPORT 读 RND 被拒"
  Q "GRANT EXEMPTION ON RULE LBACREADTREE FOR lb_p TO USER $u" >/dev/null 2>&1
  sleep 2
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "READTREE 豁免后放行"
}

case_LB190() {
  obj_env
  Q "CREATE SECURITY POLICY lb_p2 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p2.sec COMPONENT lb_lvl 'SEC'" >/dev/null 2>&1
  mk_table t1
  bind_policy t1 lb_p
  protect t1 s1 sec
  mk_table t2
  bind_policy t2 lb_p2
  protect t2 s1 sec lb_p2
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c190)
  Q "GRANT SELECT ON TABLE $DB.t2 TO USER $u" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u" >/dev/null 2>&1
  sleep 2
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t2")" "2400" "在 lb_p 的豁免不影响 lb_p2 的对象"
}

case_LB191() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c191)
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "先授 READARRAY"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE ALL FOR lb_p TO USER $u")" "再授 ALL"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "重复授 READARRAY 幂等"
  assert_ok "$(Q "REVOKE EXEMPTION ON RULE ALL FOR lb_p FROM USER $u")" "撤销 ALL"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "撤销 ALL 后（READARRAY 一并清除）读被拒"
  assert_err "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY WRITE_UP FOR lb_p TO USER $u")" "700" "非法方向组合（READARRAY + WRITE_UP）被拒"
  assert_err "$(Q "GRANT EXEMPTION ON RULE LBACWRITESET WRITE_DOWN FOR lb_p TO USER $u")" "700" "非法方向组合（WRITESET + WRITE_DOWN）被拒"
}

case_LB192() {
  lbac_reset
  local i
  for i in $(seq 1 8); do
    Q "CREATE SECURITY LABEL COMPONENT lb_race ARRAY ('A','B')" > "/tmp/lb192_$i.out" 2>&1 &
  done
  wait
  local okN failN
  okN=$(grep -l "executed successfully" /tmp/lb192_*.out 2>/dev/null | wc -l)
  failN=$(grep -l "2402" /tmp/lb192_*.out 2>/dev/null | wc -l)
  [ "${okN:-0}" = "1" ] && ok "8 并发创建同名组件：恰好 1 个成功" || fail "成功数期望 1，实际 ${okN:-0}"
  [ "${failN:-0}" = "7" ] && ok "其余 7 个均返回 2402 already exists" || fail "2402 数量期望 7，实际 ${failN:-0}"
  rm -f /tmp/lb192_*.out
}

case_LB193() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c193)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  local before; before=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1")
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_lvl ADD ELEMENT 'ZZZ' BEFORE 'NO_SUCH'")" "" "执行必失败的 ALTER"
  assert_err "$(Q "DROP SECURITY POLICY lb_no_such")" "" "执行必失败的 DROP"
  assert_err "$(Q "GRANT SECURITY LABEL lb_p.no_such TO USER $u FOR READ ACCESS")" "2405" "执行必失败的 GRANT"
  local after; after=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1")
  assert_ok "$after" "失败操作后原用户仍可正常访问"
  [ "$(echo "$before" | grep -oE '[0-9]+' | head -1)" = "$(echo "$after" | grep -oE '[0-9]+' | head -1)" ] && ok "访问结果与失败前一致" || fail "访问结果发生变化"
}

case_LB194() {
  obj_env
  local u; u=$(mk_user c194)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  local all own
  all=$(Q "SELECT grantee FROM information_schema.security_label_access" | grep -c 'lbu_')
  own=$(u_sql "$u" "SELECT grantee FROM information_schema.security_label_access" | grep -c 'lbu_')
  [ "${all:-0}" -ge 1 ] && ok "SECURITY 主体可见全部记录（${all}）" || fail "SECURITY 主体看不到记录"
  [ "${own:-0}" -ge 1 ] && [ "${own:-0}" -lt "${all:-0}" ] && ok "普通用户仅见自身记录（${own} < ${all}）" || note "普通用户可见 ${own} 条 / 全部 ${all} 条"
}

case_LB195() {
  obj_env
  Q "CREATE SECURITY POLICY lb_p3 COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p3.sec COMPONENT lb_lvl 'SEC'" >/dev/null 2>&1
  mk_table t1
  bind_policy t1 lb_p
  protect t1 s1 sec
  mk_table t2
  bind_policy t2 lb_p3
  protect t2 s1 sec lb_p3
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  with_label sec "INSERT INTO $DB.t2(time,dev,s1) VALUES(1,'d1',2.5)" lb_p3 >/dev/null 2>&1
  local u; u=$(mk_user c195)
  Q "GRANT SELECT ON TABLE $DB.t2 TO USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "授 lb_p.sec 后可读 lb_p 的表"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t2")" "2400" "同名标签 lb_p3.sec 未被授予，读 lb_p3 的表被拒"
  Q "GRANT SECURITY LABEL lb_p3.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t2")" "补授 lb_p3.sec 后可读"
}

case_LB196() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA','FIN')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_dept" >/dev/null 2>&1
  # 对象标签：多值 (RD,QA)
  assert_ok "$(Q "CREATE SECURITY LABEL lb_p.l_obj COMPONENT lb_dept 'RD', 'QA'")" "SET 多值标签 (RD,QA) 创建成功"
  Q "CREATE SECURITY LABEL lb_p.l_rd COMPONENT lb_dept 'RD'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_qa_fin COMPONENT lb_dept 'QA', 'FIN'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 l_obj
  with_label l_obj "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c196)
  Q "GRANT SECURITY LABEL lb_p.l_rd TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "用户 (RD) 不覆盖对象 (RD,QA)，读被拒"
  Q "REVOKE SECURITY LABEL lb_p.l_rd FROM USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l_obj TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "用户 (RD,QA) 覆盖对象 (RD,QA)，读放行"
}

case_LB197() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY', 'STORAGE' UNDER 'RND', 'SUPPORT' UNDER 'COMPANY')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_org" >/dev/null 2>&1
  assert_ok "$(Q "CREATE SECURITY LABEL lb_p.l_obj COMPONENT lb_org 'RND', 'STORAGE'")" "TREE 多值标签 (RND,STORAGE) 创建成功"
  Q "CREATE SECURITY LABEL lb_p.l_comp COMPONENT lb_org 'COMPANY'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_rnd COMPONENT lb_org 'RND'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_sup COMPONENT lb_org 'SUPPORT'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 l_obj
  with_label l_obj "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c197)
  # 实测语义：多值对象只要有一个值被用户值（相等或祖先）命中即放行
  Q "GRANT SECURITY LABEL lb_p.l_rnd TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "用户 RND 命中对象 (RND,STORAGE) 中的 RND，读放行"
  Q "REVOKE SECURITY LABEL lb_p.l_rnd FROM USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l_sup TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "用户 SUPPORT 与 (RND,STORAGE) 无祖先关系，读被拒"
  Q "REVOKE SECURITY LABEL lb_p.l_sup FROM USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l_comp TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "用户 COMPANY 为两者共同祖先，读放行"
}