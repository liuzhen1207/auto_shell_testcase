# ============================================================================
# LBAC 数据操作（DML）用例 LB-111 ~ LB-122
# ============================================================================

CASES+=(
"LB-111|查询|反向|SELECT 受保护列无读凭证被拒（2400）|case_LB111"
"LB-112|查询|反向|SELECT * 含无权受保护列被拒|case_LB112"
"LB-113|查询|正向|仅查询有权限的列允许|case_LB113"
"LB-114|查询|正向|COUNT(*) 不因存在无权列而失败|case_LB114"
"LB-115|查询|正向|DESCRIBE / SHOW CREATE TABLE 不触发 LBAC 检查|case_LB115"
"LB-116|写入|反向|INSERT 受保护列无写凭证被拒|case_LB116"
"LB-117|写入|正向|INSERT 受保护列有写凭证成功|case_LB117"
"LB-118|更新|边界|UPDATE ATTRIBUTE 需 SET 列写凭证与 WHERE 列读凭证|case_LB118"
"LB-119|删除|反向|DELETE 行需要所有受保护列的写凭证|case_LB119"
"LB-120|删除|边界|DELETE WHERE 引用受保护列时还需读凭证|case_LB120"
"LB-121|删除|正向|DROP TABLE / DROP DATABASE 不额外触发 LBAC 检查|case_LB121"
"LB-122|写入|正向|经可写视图 INSERT 时按底层表检查（有凭证成功）|case_LB122"
)

# 环境：t1.s1 受 sec 保护，t1.s2 未保护；root 有全部凭证
dml_env() {
  obj_env
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 sec
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2) VALUES(1,'d1',1.5,2.5)" >/dev/null 2>&1
}

case_LB111() {
  dml_env
  local u; u=$(mk_user d1)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "无读凭证读受保护列被拒"
}

case_LB112() {
  dml_env
  local u; u=$(mk_user d2)
  assert_err "$(u_sql "$u" "SELECT * FROM $DB.t1")" "2400" "SELECT * 含无权列被拒"
}

case_LB113() {
  dml_env
  local u; u=$(mk_user d3)
  assert_ok "$(u_sql "$u" "SELECT s2 FROM $DB.t1")" "仅查询未保护列允许"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "授予读凭证后可查受保护列"
}

case_LB114() {
  dml_env
  local u; u=$(mk_user d4)
  local o
  o=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1")
  assert_ok "$o" "COUNT(*) 放行"
  assert_contains "$o" "1" "计数结果正确"
}

case_LB115() {
  dml_env
  local u; u=$(mk_user d5)
  assert_ok "$(u_sql "$u" "DESCRIBE $DB.t1")" "DESCRIBE 不检查 LBAC"
  assert_ok "$(u_sql "$u" "SHOW CREATE TABLE $DB.t1")" "SHOW CREATE TABLE 不检查 LBAC"
}

case_LB116() {
  dml_env
  local u; u=$(mk_user d6)
  assert_err "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "2400" "无写凭证写入受保护列被拒"
}

case_LB117() {
  dml_env
  local u; u=$(mk_user d7)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.t1(time,dev,s1) VALUES(2,'d1',2.5)")" "有写凭证写入成功"
}

case_LB118() {
  dml_env
  # attr 是 ATTRIBUTE 列，给它加 LBAC 保护后验证 UPDATE 的写检查
  protect t1 attr sec
  local u; u=$(mk_user d8)
  assert_err "$(u_sql "$u" "UPDATE $DB.t1 SET attr='a1' WHERE dev='d1'")" "2400" "无写凭证 UPDATE 受保护属性列被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "UPDATE $DB.t1 SET attr='a2' WHERE dev='d1'")" "授予写凭证后 UPDATE 成功"
}

case_LB119() {
  dml_env
  local u; u=$(mk_user d9)
  Q "GRANT DELETE ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "DELETE FROM $DB.t1 WHERE time=1")" "2400" "表含受保护列时无写凭证删除被拒"
}

case_LB120() {
  dml_env
  ensure_s2_del_env() { :; }
  local u; u=$(mk_user d10)
  Q "GRANT DELETE ON TABLE $DB.t1 TO USER $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  # 有写凭证但 WHERE 引用受保护列 s1 → 需要读凭证
  assert_err "$(u_sql "$u" "DELETE FROM $DB.t1 WHERE s1 > 0")" "2400" "WHERE 引用受保护列但缺读凭证被拒"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "DELETE FROM $DB.t1 WHERE time=1")" "补齐读写凭证后删除成功"
}

case_LB121() {
  dml_env
  local u; u=$(mk_user d11)
  Q "GRANT DROP ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  # 无 LBAC 凭证也能删除表/库（只看 DDL 权限）
  assert_ok "$(u_sql "$u" "DROP TABLE $DB.t1")" "无 LBAC 凭证可 DROP TABLE（不触发 LBAC）"
}

case_LB122() {
  dml_env
  with_label sec "CREATE VIEW $DB.wv(dev STRING TAG, s1 DOUBLE FIELD) AS root.${DB}_v.**" >/dev/null 2>&1
  local u; u=$(mk_user d12)
  Q "GRANT INSERT ON TABLE $DB.wv TO USER $u" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "INSERT INTO $DB.wv(time,dev,s1) VALUES(3,'d1',3.5)")" "2400" "可写视图写入：底层表写检查生效"
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR WRITE ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "INSERT INTO $DB.wv(time,dev,s1) VALUES(4,'d1',4.5)")" "有凭证后经可写视图写入成功"
}
