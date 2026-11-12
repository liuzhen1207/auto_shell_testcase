# ============================================================================
# LBAC 高可用 / 持久化 / 副本一致性 / 日志用例 LB-132 ~ LB-141
# ============================================================================

CASES+=(
"LB-132|高可用|可靠性|CN 重启后 LBAC 元数据与授权仍有效|case_LB132"
"LB-133|高可用|可靠性|DN 重启后 LBAC 访问判断仍生效|case_LB133"
"LB-134|高可用|可靠性|ALTER COMPONENT ADD ELEMENT 后新标签按新版本生效|case_LB134"
"LB-135|缓存|可靠性|解除列保护后立即生效（不按旧缓存放行）|case_LB135"
"LB-136|缓存|可靠性|ALTER POLICY USE ROLE AUTHORIZATIONS 后立即生效|case_LB136"
"LB-137|一致性|可靠性|三个 CN 的 LBAC 元数据一致（schema 3 副本）|case_LB137"
"LB-138|一致性|可靠性|数据 2 副本下写入后多次查询结果一致|case_LB138"
"LB-139|持久化|可靠性|重启后 label grant / exemption 仍存在|case_LB139"
"LB-140|日志|可靠性|正常授权访问路径无异常 ERROR|case_LB140"
"LB-141|并发|并发|并发对同一用户授予同一标签同类型：一成功一失败|case_LB141"
)

case_LB132() {
  dml_env
  local u; u=$(mk_user h1)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "重启前：有凭证可读"
  echo "  重启 CN 172.16.2.28 ..."
  cn_restart 172.16.2.28
  echo "  重启后 Running=$(wait_running 8 300)"
  # 元数据仍可见
  assert_contains "$(Q "SELECT policy_name FROM information_schema.security_policies")" "lb_p" "重启后策略仍存在"
  assert_contains "$(Q "SELECT label_name FROM information_schema.security_labels")" "sec" "重启后标签仍存在"
  # 授权仍有效
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "重启后授权仍有效（可读）"
}

case_LB133() {
  dml_env
  local u; u=$(mk_user h2)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  echo "  重启 DN 172.16.2.4 ..."
  dn_restart 172.16.2.4
  echo "  重启后 Running=$(wait_running 8 300)"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "DN 重启后 LBAC 判断仍生效（可读）"
  local u2; u2=$(mk_user h2b)
  assert_err "$(u_sql "$u2" "SELECT s1 FROM $DB.t1")" "2400" "DN 重启后无凭证用户仍被拒"
}

case_LB134() {
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('A','B')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL lb_p.la COMPONENT lb_lvl 'A'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.la TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 la
  with_label la "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
  local u; u=$(mk_user h3)
  Q "GRANT SECURITY LABEL lb_p.la TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "旧标签 la 可读"
  # 追加元素 C（位于 A 之前，等级更高）
  assert_ok "$(Q "ALTER SECURITY LABEL COMPONENT lb_lvl ADD ELEMENT 'C' BEFORE 'A'")" "追加元素 C"
  Q "CREATE SECURITY LABEL lb_p.lc COMPONENT lb_lvl 'C'" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.lc TO USER root FOR ALL ACCESS" >/dev/null 2>&1
  protect t1 s2 lc
  with_label lc "INSERT INTO $DB.t1(time,dev,s2) VALUES(2,'d1',2.5)" >/dev/null 2>&1
  local u2; u2=$(mk_user h3b)
  Q "GRANT SECURITY LABEL lb_p.lc TO USER $u2 FOR WRITE ACCESS" >/dev/null 2>&1
  # lc 用户（C 级）写 s2（C 保护）应允许
  assert_ok "$(u_sql "$u2" "INSERT INTO $DB.t1(time,dev,s2) VALUES(3,'d1',3.5)")" "新标签按新版本生效（C 写 C 允许）"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "旧标签仍可读（版本兼容）"
}

case_LB135() {
  dml_env
  local u; u=$(mk_user h4)
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "解除前：无凭证被拒"
  assert_ok "$(with_label sec "ALTER TABLE $DB.t1 ALTER COLUMN s1 DROP COLUMN SECURITY")" "持旧标签凭证的用户解除列保护"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "解除后立即允许（无旧缓存放行问题）"
}

case_LB136() {
  dml_env
  local u r; u=$(mk_user h5); r=$(mk_role h5)
  Q "GRANT ROLE $r TO $u" >/dev/null 2>&1
  Q "GRANT SECURITY LABEL lb_p.sec TO ROLE $r FOR READ ACCESS" >/dev/null 2>&1
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "IGNORE：角色标签不参与"
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p USE ROLE AUTHORIZATIONS")" "切换为 USE"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "切换后立即生效（角色标签参与）"
  assert_ok "$(Q "ALTER SECURITY POLICY lb_p IGNORE ROLE AUTHORIZATIONS")" "切回 IGNORE"
  assert_err "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "2400" "切回后立即失效"
}

case_LB137() {
  dml_env
  local ips="172.16.2.26 172.16.2.27 172.16.2.28"
  local base="" cur ip same=1
  for ip in $ips; do
    cur=$(timeout 40 $CLI -h $ip -p 6667 -u root -pw "$PW" -sql_dialect table -e "SELECT policy_name, component_count FROM information_schema.security_policies" 2>/dev/null | grep lb_p | tr -d ' ')
    echo "  CN $ip -> ${cur:-（空）}"
    if [ -z "$base" ]; then base="$cur"; elif [ "$base" != "$cur" ]; then same=0; fi
  done
  [ "$same" = "1" ] && ok "三个 CN 的 LBAC 元数据一致" || fail "三个 CN 元数据不一致"
}

case_LB138() {
  dml_env
  local u; u=$(mk_user h6)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  with_label sec "INSERT INTO $DB.t1(time,dev,s1,s2) VALUES(10,'d2',10.5,20.5)" >/dev/null 2>&1
  local a b c
  a=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1" | grep -E '^\| *[0-9]+' | tr -dc '0-9')
  b=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1" | grep -E '^\| *[0-9]+' | tr -dc '0-9')
  dn_restart 172.16.2.6 >/dev/null 2>&1
  wait_running 8 300 >/dev/null 2>&1 || true
  c=$(u_sql "$u" "SELECT COUNT(*) FROM $DB.t1" | grep -E '^\| *[0-9]+' | tr -dc '0-9')
  echo "  行数：重启前 $a/$b，重启后 $c"
  { [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; } && ok "多次查询与 DN 重启后结果一致（2 副本）" || fail "查询结果不一致（$a/$b/$c）"
}

case_LB139() {
  dml_env
  local u; u=$(mk_user h7)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  Q "GRANT EXEMPTION ON RULE LBACREADARRAY FOR lb_p TO USER $u" >/dev/null 2>&1
  cn_restart 172.16.2.27
  wait_running 8 300 >/dev/null 2>&1 || true
  local o
  o=$(Q "SELECT grantee, label_name, access_type FROM information_schema.security_label_access" | grep "$u")
  assert_contains "$o" "sec" "重启后 label grant 仍在"
  o=$(Q "SELECT grantee, rule_name FROM information_schema.security_policy_exemptions" | grep "$u")
  assert_contains "$o" "LBACREADARRAY" "重启后 exemption 仍在"
  assert_ok "$(u_sql "$u" "SELECT s1 FROM $DB.t1")" "重启后授权仍生效"
}

case_LB140() {
  dml_env
  local u; u=$(mk_user h8)
  Q "GRANT SECURITY LABEL lb_p.sec TO USER $u FOR READ ACCESS" >/dev/null 2>&1
  log_mark
  local o
  o=$(u_sql "$u" "SELECT s1 FROM $DB.t1")
  o="$o$(u_sql "$u" "SELECT s2 FROM $DB.t1")"
  sleep 3
  local errs
  errs=$(log_errors | tail -1)
  echo "  窗口内 ERROR 行数（未过滤）：$errs"
  # 过滤已知 HA/框架噪声
  local filtered
  filtered=$(log_errors | grep -viE 'Ratis|GrpcLogAppender|PIPE_HEARTBEAT|UPDATE_REGION_ROUTE_MAP|RouteBalancer|ScheduledExecutorUtil|openSession|Fail to start server|already exist' | grep -vE '^[0-9]+$' | wc -l)
  [ "$filtered" = "0" ] && ok "正常授权访问路径无异常 ERROR（过滤已知 HA 噪声）" || fail "发现 $filtered 条疑似异常 ERROR 日志"
}

case_LB141() {
  dml_env
  local u; u=$(mk_user h9)
  ( Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" > /tmp/lbac_c1.txt 2>&1 ) &
  ( Q "GRANT SECURITY LABEL lb_p.pub TO USER $u FOR READ ACCESS" > /tmp/lbac_c2.txt 2>&1 ) &
  wait
  local s f
  s=$(cat /tmp/lbac_c1.txt /tmp/lbac_c2.txt | grep -ci 'successfully')
  f=$(cat /tmp/lbac_c1.txt /tmp/lbac_c2.txt | grep -ciexception)
  echo "  并发结果：成功 $s 次，报错 $f 次"
  if [ "$s" -ge 1 ] && [ "$f" -ge 1 ]; then ok "并发授权一成功一失败（符合预期）"; else fail "并发授权结果异常（成功 $s，报错 $f）"; fi
  rm -f /tmp/lbac_c1.txt /tmp/lbac_c2.txt
}
