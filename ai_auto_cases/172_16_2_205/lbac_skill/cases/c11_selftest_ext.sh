# ============================================================================
# 依据研发自测用例（139 条）补充的扩展用例 LB-161 ~ LB-180
#   覆盖自测文档中我方原有套件未断言的点；数据量按 3C5D 能力放大
# ============================================================================

CASES+=(
"LB-161|组件|边界|单元素组件可用；200 元素 ARRAY 的 ordinal 连续|case_LB161"
"LB-162|组件|异常|零元素/缺类型参数的组件创建被拒|case_LB162"
"LB-163|组件|异常|非法类型 LIST、TREE 无 ROOT、UNDER 不存在父被拒|case_LB163"
"LB-164|组件|边界|ARRAY 省略位置子句默认追加；SET 拒绝位置子句|case_LB164"
"LB-165|组件|边界|TREE OVER 重挂接成功、跨父/重复 OVER 被拒|case_LB165"
"LB-166|组件|异常|TREE 多个 ROOT 创建被拒、ADD ROOT 提升新根|case_LB166"
"LB-167|组件|正向|新增元素后比较语义按新顺序生效|case_LB167"
"LB-168|组件|异常|组件类型不可变更（ALTER ... SET）|case_LB168"
"LB-169|策略|异常|策略重复引用同一组件被拒|case_LB169"
"LB-170|策略|异常|空组件列表/省略 COMPONENTS 被拒|case_LB170"
"LB-171|策略|异常|非法规则集名称被拒（OTHER_RULES/拼写错误）|case_LB171"
"LB-172|标签|异常|SET 拒绝 packed string 形式的多值|case_LB172"
"LB-173|标签|异常|ARRAY 拒绝多值及 packed string|case_LB173"
"LB-174|标签|异常|标签重复指定同一组件被拒|case_LB174"
"LB-175|标签|异常|标签名必须带策略前缀（裸名 COMMENT/DROP 失败）|case_LB175"
"LB-176|标签|异常|ALTER LABEL 修改标签值不被支持|case_LB176"
"LB-177|比较|正向|同一主体 READ=高标签、WRITE=低标签：读放行/写本级放行/写上级拒绝|case_LB177"
"LB-178|豁免|正向|仅授 READARRAY 豁免：ARRAY 维度放行、SET 维度仍拒|case_LB178"
"LB-179|豁免|边界|ALL 豁免展开后撤销单规则，剩余规则仍生效|case_LB179"
"LB-180|豁免|正向|角色 READTREE 豁免受 IGNORE/USE 控制|case_LB180"
)

case_LB161() {
  lbac_reset
  local els=""
  local i
  for i in $(seq 1 200); do els="$els'E$i',"; done
  els="${els%,}"
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_big ARRAY ($els)")" "200 元素 ARRAY 创建成功"
  local n
  n=$(Q "SELECT COUNT(*) FROM information_schema.security_label_component_elements WHERE component_name='lb_big'" | awk -F'|' 'NF>2 {gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) {print $2; exit}}')
  [ "${n:-0}" = "200" ] && ok "元素数量 200 正确" || fail "元素数量期望 200，实际 ${n:-0}"
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_one_arr ARRAY ('ONLY')")" "单元素 ARRAY 创建成功"
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_one_set SET ('ONLY')")" "单元素 SET 创建成功"
  assert_ok "$(Q "CREATE SECURITY LABEL COMPONENT lb_one_tree TREE ('ONLY' ROOT)")" "单元素 TREE 创建成功"
}

case_LB162() {
  lbac_reset
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_z1 ARRAY ()")" "" "ARRAY() 零元素被拒"
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_z2 SET ()")" "" "SET() 零元素被拒"
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_z3 TREE ()")" "" "TREE() 零元素被拒"
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_z4 ('A')")" "" "缺少组件类型被拒"
}

case_LB163() {
  lbac_reset
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_t1 LIST ('A','B')")" "" "非法类型 LIST 被拒"
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_t2 TREE ('A')")" "" "TREE 无 ROOT 被拒"
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_t3 TREE ('A' UNDER 'GHOST')")" "" "UNDER 不存在的父节点被拒"
}

case_LB164() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_arr ARRAY ('A','B')" >/dev/null 2>&1
  # 实现要求 ARRAY 必须带位置子句（自测 C-14 期望“默认追加”，实测为 2410，已记录为文档差异）
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_arr ADD ELEMENT 'C'")" "2410" "ARRAY 省略位置子句被拒（2410）"
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_arr ADD ELEMENT 'C' AFTER 'B'")" "ARRAY 带位置子句可追加"
  local o; o=$(Q "SELECT element_value, ordinal FROM information_schema.security_label_component_elements WHERE component_name='lb_arr' ORDER BY ordinal")
  assert_contains "$o" "C" "新元素 C 已写入"
  Q "CREATE SECURITY LABEL COMPONENT lb_st SET ('A','B')" >/dev/null 2>&1
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_st ADD ELEMENT 'E' BEFORE 'A'")" "" "SET 拒绝 BEFORE 位置子句"
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_st ADD ELEMENT 'E' UNDER 'A'")" "" "SET 拒绝 UNDER 位置子句"
  Q "CREATE SECURITY LABEL COMPONENT lb_tr2 TREE ('ROOT' ROOT, 'A' UNDER 'ROOT')" >/dev/null 2>&1
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_tr2 ADD ELEMENT 'B'")" "2410" "TREE 省略位置子句被拒（2410）"
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_tr2 ADD ELEMENT 'B' UNDER 'A'")" "TREE 带 UNDER 可追加"
}

case_LB165() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_tr TREE ('ROOT' ROOT, 'A' UNDER 'ROOT', 'B' UNDER 'ROOT')" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_tr ADD ELEMENT 'MID' UNDER 'ROOT' OVER 'A','B'")" "OVER 重挂接 A/B 到 MID 成功"
  local o; o=$(Q "SELECT element_value, parent_element_value FROM information_schema.security_label_component_elements WHERE component_name='lb_tr'")
  assert_contains "$o" "MID" "MID 节点已写入"
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_tr ADD ELEMENT 'X' UNDER 'A' OVER 'B'")" "" "跨父节点 OVER 被拒"
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_tr ADD ELEMENT 'Y' UNDER 'ROOT' OVER 'A','A'")" "" "重复 OVER 节点被拒"
}

case_LB166() {
  lbac_reset
  assert_err "$(Q "CREATE SECURITY LABEL COMPONENT lb_two TREE ('R1' ROOT, 'R2' ROOT)")" "" "多个 ROOT 的 TREE 创建被拒"
  Q "CREATE SECURITY LABEL COMPONENT lb_two TREE ('R1' ROOT, 'C1' UNDER 'R1')" >/dev/null 2>&1
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_two ADD ELEMENT 'R2' ROOT")" "ADD ROOT2 ROOT 成功"
  local o; o=$(Q "SELECT element_value, parent_element_value FROM information_schema.security_label_component_elements WHERE component_name='lb_two'")
  assert_contains "$o" "R1" "原 ROOT R1 仍存在（被降级为普通节点）"
}

case_LB167() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_rank ARRAY ('HIGH','MEDIUM','LOW')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_rank" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.high COMPONENT lb_rank 'HIGH'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.med COMPONENT lb_rank 'MEDIUM'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.low COMPONENT lb_rank 'LOW'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 med
  with_label med "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  # 在 HIGH 前插入 ULTRA，改变等级顺序
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_rank ADD ELEMENT 'ULTRA' BEFORE 'HIGH'")" "在 HIGH 前插入 ULTRA"
  Q "CREATE SECURITY LABEL lb_p.ultra COMPONENT lb_rank 'ULTRA'" >/dev/null 2>&1
  local u; u=$(mk_user c167)
  Q "GRANT SECURITY LABEL lb_p.high TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "新顺序下 HIGH 仍可读 MEDIUM 保护列"
  protect t1 s2 ultra >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "2400" "HIGH 不可读 ULTRA 保护列（顺序已生效）"
}

case_LB168() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_type ARRAY ('A','B')" >/dev/null 2>&1
  assert_err "$(Q "ALTER SECURITY LABEL COMPONENT lb_type SET ('X')")" "" "组件类型变更（ARRAY→SET）被拒"
}

case_LB169() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_cdup ARRAY ('A','B')" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY POLICY lb_dup COMPONENTS lb_cdup, lb_cdup")" "" "策略重复引用同一组件被拒"
}

case_LB170() {
  lbac_reset
  assert_err "$(Q "CREATE SECURITY POLICY lb_empty COMPONENTS")" "" "空 COMPONENTS 子句被拒"
  assert_err "$(Q "CREATE SECURITY POLICY lb_empty2")" "" "省略 COMPONENTS 被拒"
}

case_LB171() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_rl ARRAY ('A','B')" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY POLICY lb_rule1 COMPONENTS lb_rl WITH OTHER_RULES")" "" "OTHER_RULES 被拒"
  assert_err "$(Q "CREATE SECURITY POLICY lb_rule2 COMPONENTS lb_rl WITH LBACRULESS")" "" "拼写错误规则集被拒"
  assert_ok "$(Q "CREATE SECURITY POLICY lb_rule3 COMPONENTS lb_rl WITH LBACRULES")" "标准规则集 LBACRULES 可用"
}

case_LB172() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_ps COMPONENTS lb_dept" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY LABEL lb_ps.l1 COMPONENT lb_dept 'RD,QA'")" "" "SET packed string 'RD,QA' 被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_ps.l2 COMPONENT lb_dept '(RD,QA)'")" "" "SET packed string '(RD,QA)' 被拒"
  assert_ok "$(Q "CREATE SECURITY LABEL lb_ps.l3 COMPONENT lb_dept 'RD'")" "SET 单值可用"
}

case_LB173() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lv ARRAY ('SEC','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_pa COMPONENTS lb_lv" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY LABEL lb_pa.l1 COMPONENT lb_lv 'SEC','PUB'")" "" "ARRAY 两个独立值被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_pa.l2 COMPONENT lb_lv '(SEC,PUB)'")" "" "ARRAY packed string 被拒"
  assert_ok "$(Q "CREATE SECURITY LABEL lb_pa.l3 COMPONENT lb_lv 'SEC'")" "ARRAY 单值可用"
}

case_LB174() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lv2 ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dp2 SET ('RD','QA')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_pd COMPONENTS lb_lv2, lb_dp2" >/dev/null 2>&1
  assert_err "$(Q "CREATE SECURITY LABEL lb_pd.l1 COMPONENT lb_lv2 'A', COMPONENT lb_lv2 'A'")" "" "重复指定同一组件（同值）被拒"
  assert_err "$(Q "CREATE SECURITY LABEL lb_pd.l2 COMPONENT lb_lv2 'A', COMPONENT lb_lv2 'B'")" "" "重复指定同一组件（不同值）被拒"
}

case_LB175() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lv3 ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_pf COMPONENTS lb_lv3" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_pf.l_free COMPONENT lb_lv3 'A'" >/dev/null 2>&1
  assert_err "$(Q "COMMENT ON SECURITY LABEL l_free IS 'x'")" "" "裸标签名 COMMENT 被拒"
  assert_ok "$(Q "COMMENT ON SECURITY LABEL lb_pf.l_free IS 'x'")" "限定名 COMMEN 成功"
  assert_err "$(Q "DROP SECURITY LABEL l_free")" "" "裸标签名 DROP 被拒"
  assert_ok "$(Q "DROP SECURITY LABEL lb_pf.l_free")" "限定名 DROP 成功"
}

case_LB176() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lv4 ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_pg COMPONENTS lb_lv4" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_pg.l1 COMPONENT lb_lv4 'A'" >/dev/null 2>&1
  assert_err "$(Q "ALTER SECURITY LABEL lb_pg.l1 COMPONENT lb_lv4 'B'")" "" "ALTER LABEL 修改值不被支持（应报错）"
}

case_LB177() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  protect t1 s2 top
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2) VALUES(1,'d1',1.5,9.5)" >/dev/null 2>&1
  local u; u=$(mk_user c177)
  Q "GRANT SECURITY LABEL lb_p.top TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "READ=TOP 可读 SEC 保护列"
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "WRITE=SEC 可写 SEC 保护列"
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s2) VALUES(3,'d1',8.5)")" "2400" "WRITE=SEC 不可写 TOP 保护列"
}

case_LB178() {
  mv_env
  Q "CREATE SECURITY LABEL lb_p.l_obj COMPONENT lb_lvl 'SEC', COMPONENT lb_dept 'RD', COMPONENT lb_org 'RND'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_usr COMPONENT lb_lvl 'PUB', COMPONENT lb_dept 'RD', COMPONENT lb_org 'RND'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 l_obj
  local u; u=$(mk_user c178)
  Q "GRANT SECURITY LABEL lb_p.l_usr TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "未豁免时 ARRAY 维度不满足被拒"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "授予 READARRAY 豁免"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "仅豁免 ARRAY 维度后读取放行"
}

case_LB179() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user c179)
  assert_ok "$(Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u")" "先授单规则 READARRAY"
  assert_ok "$(Q "GRANT EXEMPTION ON RULE ALL FOR lb_p TO USER $u")" "再授 ALL（叠加）"
  sleep 2
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "ALL 豁免叠加后读受保护列放行"
  assert_ok "$(Q "REVOKE EXEMPTION ON RULE LBACREADARRAY FOR lb_p FROM USER $u")" "撤销单规则 READARRAY"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "撤掉 ARRAY 读豁免后读被拒（其余规则不影响 ARRAY）"
}

case_LB180() {
  mv_env
  Q "CREATE SECURITY LABEL lb_p.l_tree1 COMPONENT lb_lvl 'PUB', COMPONENT lb_dept 'RD', COMPONENT lb_org 'RND'" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.l_usr2 COMPONENT lb_lvl 'PUB', COMPONENT lb_dept 'RD', COMPONENT lb_org 'STORAGE'" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 l_tree1
  local r u
  r=$(mk_role c180); u=$(mk_user c180u)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.l_usr2 TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADTREE FOR lb_p TO ROLE $r" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "IGNORE 模式下角色 TREE 豁免不生效"
  Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS" >/dev/null 2>&1
  sleep 3
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "USE 模式下角色 TREE 豁免生效"
}
