# ============================================================================
# LBAC 标签比较语义用例 LB-069 ~ LB-096（核心）
# 覆盖 ARRAY/SET/TREE 的 READ/WRITE 规则、空值规则、多组件 AND、ALL 访问
# ============================================================================

CASES+=(
"LB-069|比较|正向|ARRAY READ：用户 SEC 读 INT 保护列允许|case_LB069"
"LB-070|比较|正向|ARRAY READ：用户 SEC 读 SEC 保护列允许|case_LB070"
"LB-071|比较|反向|ARRAY READ：用户 SEC 读 TOP 保护列拒绝|case_LB071"
"LB-072|比较|边界|ARRAY READ：空用户标签读 PUB 保护列拒绝|case_LB072"
"LB-073|比较|边界|ARRAY READ：空对象保护值不阻挡任何用户值|case_LB073"
"LB-074|比较|边界|ARRAY READ：双方均为空值允许|case_LB074"
"LB-075|比较|反向|ARRAY WRITE：SEC 写 INT 保护列拒绝（下写）|case_LB075"
"LB-076|比较|正向|ARRAY WRITE：SEC 写 SEC 保护列允许|case_LB076"
"LB-077|比较|反向|ARRAY WRITE：SEC 写 TOP 保护列拒绝（上写）|case_LB077"
"LB-078|比较|边界|ARRAY WRITE：空用户标签写 PUB 保护列拒绝|case_LB078"
"LB-079|比较|边界|ARRAY WRITE：用户 PUB 写空保护值允许（不算下写）|case_LB079"
"LB-080|比较|边界|ARRAY WRITE：双方均为空值允许|case_LB080"
"LB-081|比较|正向|SET READ：用户 (RD,QA) 读 RD 保护列允许|case_LB081"
"LB-082|比较|反向|SET READ：用户 RD 读 (RD,QA) 保护列拒绝|case_LB082"
"LB-083|比较|边界|SET READ：空用户标签读 RD 保护列拒绝|case_LB083"
"LB-084|比较|边界|SET READ：用户 RD 读空保护值允许|case_LB084"
"LB-085|比较|正向|SET WRITE：用户 (RD,QA) 写 RD 保护列允许|case_LB085"
"LB-086|比较|反向|SET WRITE：用户 RD 写 (RD,QA) 保护列拒绝|case_LB086"
"LB-087|比较|正向|TREE READ：用户 COMPANY 读 RND 保护列允许（祖先）|case_LB087"
"LB-088|比较|正向|TREE READ：用户 RND 读 STORAGE 保护列允许（祖先）|case_LB088"
"LB-089|比较|反向|TREE READ：用户 STORAGE 读 RND 保护列拒绝（后代）|case_LB089"
"LB-090|比较|边界|TREE READ：空用户标签读 RND 保护列拒绝|case_LB090"
"LB-091|比较|正向|TREE WRITE：用户 COMPANY 写 STORAGE 保护列允许|case_LB091"
"LB-092|比较|反向|TREE WRITE：用户 STORAGE 写 RND 保护列拒绝|case_LB092"
"LB-093|比较|边界|默认空标签：无任何授权的用户读 PUB 保护列被拒、读未保护列允许|case_LB093"
"LB-094|比较|反向|多组件 AND：任一组件不满足即拒绝（dept 缺 QA）|case_LB094"
"LB-095|比较|正向|多组件 AND：所有组件均满足时允许|case_LB095"
"LB-096|比较|正向|ALL ACCESS 授权可读可写|case_LB096"
)

# 允许：用户标签 u_lbl 对对象保护列 obj_lbl 有 READ/WRITE
arr_allow() {  # $1=用户标签 $2=对象标签 $3=访问类型(READ/WRITE)  $4=描述
  arr_env "$2"
  local u; u=$(mk_user "c$RANDOM")
  Q "GRANT SECURITY LABEL lb_p.$1 TO USER $u FOR $3 ACCESS" >/dev/null 2>&1
  local sql o
  if [ "$3" = "READ" ]; then
    o=$(u_sql "$u" "SELECT s1 FROM $DB.t1")
    assert_ok "$o" "$4"
  else
    o=$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")
    assert_ok "$o" "$4"
  fi
  echo "$u" > /tmp/lbac_case_user
}

arr_deny() {  # $1=用户标签（空=不授权） $2=对象标签 $3=访问类型 $4=描述
  arr_env "$2"
  local u; u=$(mk_user "c$RANDOM")
  [ -n "$1" ] && Q "GRANT SECURITY LABEL lb_p.$1 TO USER $u FOR $3 ACCESS" >/dev/null 2>&1
  local o
  if [ "$3" = "READ" ]; then
    o=$(u_sql "$u" "SELECT s1 FROM $DB.t1")
  else
    o=$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")
  fi
  assert_err "$o" "2400" "$4"
}

case_LB069() { arr_allow sec int READ "ARRAY READ：SEC 读 INT 允许"; }
case_LB070() { arr_allow sec sec READ "ARRAY READ：SEC 读 SEC 允许"; }
case_LB071() { arr_deny  sec top READ "ARRAY READ：SEC 读 TOP 拒绝"; }
case_LB072() { arr_deny  "" pub READ "ARRAY READ：空标签读 PUB 拒绝"; }

case_LB073() {
  # 对象保护值为空：多组件策略下只用 dept 保护（lvl 为空）
  mv_env
  mk_lbl sec_lvl "COMPONENT lb_lvl 'SEC', COMPONENT lb_dept 'RD'"
  mk_lbl obj_empty_lvl "COMPONENT lb_dept 'RD'"
  setup_col s1 obj_empty_lvl
  local u; u=$(mk_user c73)
  Q "GRANT SECURITY LABEL lb_p.sec_lvl TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "ARRAY 对象保护值为空：允许"
}

case_LB074() {
  mv_env
  mk_lbl obj_empty_lvl "COMPONENT lb_dept 'RD'"
  mk_lbl u_empty_lvl "COMPONENT lb_dept 'RD'"
  setup_col s1 obj_empty_lvl
  local u; u=$(mk_user c74)
  Q "GRANT SECURITY LABEL lb_p.u_empty_lvl TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "ARRAY 双方空值：允许"
}

case_LB075() { arr_deny  sec int WRITE "ARRAY WRITE：SEC 写 INT 拒绝（下写）"; }
case_LB076() { arr_allow sec sec WRITE "ARRAY WRITE：SEC 写 SEC 允许"; }
case_LB077() { arr_deny  sec top WRITE "ARRAY WRITE：SEC 写 TOP 拒绝（上写）"; }
case_LB078() { arr_deny  "" pub WRITE "ARRAY WRITE：空标签写 PUB 拒绝"; }

case_LB079() {
  mv_env
  mk_lbl pub_lvl "COMPONENT lb_lvl 'PUB', COMPONENT lb_dept 'RD'"
  mk_lbl obj_empty_lvl "COMPONENT lb_dept 'RD'"
  setup_col s1 obj_empty_lvl
  local u; u=$(mk_user c79)
  Q "GRANT SECURITY LABEL lb_p.pub_lvl TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "ARRAY WRITE：PUB 写空保护值允许"
}

case_LB080() {
  mv_env
  mk_lbl obj_empty_lvl "COMPONENT lb_dept 'RD'"
  mk_lbl u_empty_lvl "COMPONENT lb_dept 'RD'"
  setup_col s1 obj_empty_lvl
  local u; u=$(mk_user c80)
  Q "GRANT SECURITY LABEL lb_p.u_empty_lvl TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "ARRAY WRITE：双方空值允许"
}

# SET 用例辅助
set_case() {  # $1=用户 dept 值 $2=对象 dept 值 $3=访问类型 $4=期望 allow/deny $5=描述
  mv_env
  mk_lbl obj_l "COMPONENT lb_dept $2"
  mk_lbl usr_l "COMPONENT lb_dept $1"
  setup_col s1 obj_l
  local u; u=$(mk_user "s$RANDOM")
  Q "GRANT SECURITY LABEL lb_p.usr_l TO USER $u FOR $3 ACCESS" >/dev/null 2>&1
  local o
  if [ "$3" = "READ" ]; then o=$(u_sql "$u" "SELECT s1 FROM $DB.t1"); else o=$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)"); fi
  if [ "$4" = "allow" ]; then assert_ok "$o" "$5"; else assert_err "$o" "2400" "$5"; fi
}

case_LB081() { set_case "'RD','QA'" "'RD'" READ allow "SET READ：用户 (RD,QA) 读 RD 允许"; }
case_LB082() { set_case "'RD'" "'RD','QA'" READ deny "SET READ：用户 RD 读 (RD,QA) 拒绝"; }
case_LB083() { set_case "''" "'RD'" READ deny "SET READ：空标签读 RD 拒绝"; }
case_LB084() { set_case "'RD'" "''" READ allow "SET READ：用户 RD 读空保护值允许"; }
case_LB085() { set_case "'RD','QA'" "'RD'" WRITE allow "SET WRITE：用户 (RD,QA) 写 RD 允许"; }
case_LB086() { set_case "'RD'" "'RD','QA'" WRITE deny "SET WRITE：用户 RD 写 (RD,QA) 拒绝"; }

# TREE 用例辅助
tree_case() {  # $1=用户 org 值 $2=对象 org 值 $3=访问类型 $4=allow/deny $5=描述
  mv_env
  mk_lbl obj_l "COMPONENT lb_org $2"
  mk_lbl usr_l "COMPONENT lb_org $1"
  setup_col s1 obj_l
  local u; u=$(mk_user "t$RANDOM")
  Q "GRANT SECURITY LABEL lb_p.usr_l TO USER $u FOR $3 ACCESS" >/dev/null 2>&1
  local o
  if [ "$3" = "READ" ]; then o=$(u_sql "$u" "SELECT s1 FROM $DB.t1"); else o=$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)"); fi
  if [ "$4" = "allow" ]; then assert_ok "$o" "$5"; else assert_err "$o" "2400" "$5"; fi
}

case_LB087() { tree_case "'COMPANY'" "'RND'" READ allow "TREE READ：COMPANY 读 RND 允许"; }
case_LB088() { tree_case "'RND'" "'STORAGE'" READ allow "TREE READ：RND 读 STORAGE 允许"; }
case_LB089() { tree_case "'STORAGE'" "'RND'" READ deny "TREE READ：STORAGE 读 RND 拒绝"; }
case_LB090() { tree_case "''" "'RND'" READ deny "TREE READ：空标签读 RND 拒绝"; }
case_LB091() { tree_case "'COMPANY'" "'STORAGE'" WRITE allow "TREE WRITE：COMPANY 写 STORAGE 允许"; }
case_LB092() { tree_case "'STORAGE'" "'RND'" WRITE deny "TREE WRITE：STORAGE 写 RND 拒绝"; }

case_LB093() {
  arr_env pub
  local u; u=$(mk_user c93)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "无授权用户读 PUB 保护列被拒"
  assert_ok "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "同一用户读未保护列允许"
}

case_LB094() {
  mv_env
  mk_lbl obj_l "COMPONENT lb_lvl 'INT', COMPONENT lb_dept 'RD','QA'"
  mk_lbl usr_l "COMPONENT lb_lvl 'SEC', COMPONENT lb_dept 'RD'"
  setup_col s1 obj_l
  local u; u=$(mk_user c94)
  Q "GRANT SECURITY LABEL lb_p.usr_l TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "多组件 AND：dept 缺 QA 时拒绝"
}

case_LB095() {
  mv_env
  mk_lbl obj_l "COMPONENT lb_lvl 'INT', COMPONENT lb_dept 'RD'"
  mk_lbl usr_l "COMPONENT lb_lvl 'SEC', COMPONENT lb_dept 'RD','QA'"
  setup_col s1 obj_l
  local u; u=$(mk_user c95)
  Q "GRANT SECURITY LABEL lb_p.usr_l TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "多组件 AND：全部满足时允许"
}

case_LB096() {
  arr_env sec
  local u; u=$(mk_user c96)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "ALL ACCESS：读允许"
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "ALL ACCESS：写允许"
}
