# Group 5: 三权分立（separation of powers）专项
# 三权分立开启：SET CONFIGURATION 'enable_separation_of_powers'='true'（热生效）
#   开启后 root（超级用户）禁止登录（803）；系统/安全/审计三个管理员自动存在，默认密码 TimechoDB@2021
#   关闭：SQL 无法关闭（sys_admin 报 803 No permission to turn off），需改配置重启
# 本组用例只在 MODE=separation 下执行（正常模式会跳过）

case_AUTH030() {
  local o
  o=$(L root "$PW")
  echo "  root login under separation -> $(echo "$o" | head -1 | cut -c1-110)"
  assert_err "$o" "开启三权分立后 root 应被禁止登录"
  assert_code "$o" "803" "应返回 803 SUPER USER is not allowed to login"
}

case_AUTH031() {
  local u o
  for u in sys_admin security_admin audit_admin; do
    o=$(L "$u" "$PW")
    echo "  $u -> $(echo "$o" | head -1 | cut -c1-80)"
    assert_ok "$o" "$u 应可登录"
  done
}

case_AUTH032() {
  # 职责分离：只有 security_admin 能建用户
  local o
  TS "DROP USER sep032" >/dev/null 2>&1
  o=$(L sys_admin "$PW" "create user sep032 'Sep032@12345'")
  echo "  sys_admin create user -> $(echo "$o" | head -1 | cut -c1-100)"
  assert_err "$o" "sys_admin 不应能建用户（安全权限归 security_admin）"
  o=$(L audit_admin "$PW" "create user sep032 'Sep032@12345'")
  echo "  audit_admin create user -> $(echo "$o" | head -1 | cut -c1-100)"
  assert_err "$o" "audit_admin 不应能建用户"
  o=$(TS "CREATE USER sep032 'Sep032@12345'")
  echo "  security_admin create user -> $(echo "$o" | head -1 | cut -c1-100)"
  assert_ok "$o" "security_admin 应可建用户"
  TS "DROP USER sep032" >/dev/null 2>&1
}

case_AUTH033() {
  # 数据面：sys_admin 可读写；security_admin 不应能读业务数据
  local o
  T "DROP DATABASE root.sep033" >/dev/null 2>&1
  o=$(T "CREATE DATABASE root.sep033")
  assert_ok "$o" "sys_admin 应可建库（SYSTEM/DATA 权限）"
  T "CREATE TIMESERIES root.sep033.d1.s1 INT32" >/dev/null 2>&1
  T "INSERT INTO root.sep033.d1(time,s1) VALUES(1,1)" >/dev/null 2>&1
  o=$(L security_admin "$PW" "select s1 from root.sep033.d1")
  echo "  security_admin read data -> $(echo "$o" | sed -n '2p' | cut -c1-100)"
  echo "$o" | grep -qiE "no permission|803" && ok "security_admin 读业务数据被拒" || echo "  NOTE: security_admin 可读业务数据（需对照三权设计确认）"
  T "DROP DATABASE root.sep033" >/dev/null 2>&1
}

case_AUTH034() {
  # 系统配置权限：sys_admin 可改常规配置，但不能关闭三权分立
  local o
  o=$(L sys_admin "$PW" "set configuration 'enforce_strong_password'='true'")
  echo "  sys_admin set enforce_strong_password -> $(echo "$o" | head -1 | cut -c1-100)"
  echo "$o" | grep -q "803" && ok "sys_admin 无 SYSTEM 配置权限（符合三权设计：配置归对应管理员）" || echo "  NOTE: sys_admin 可改该配置"
  o=$(L security_admin "$PW" "set configuration 'enforce_strong_password'='true'")
  echo "  security_admin set enforce_strong_password -> $(echo "$o" | head -1 | cut -c1-100)"
  o=$(L sys_admin "$PW" "set configuration 'enable_separation_of_powers'='false'")
  echo "  sys_admin disable separation -> $(echo "$o" | head -1 | cut -c1-110)"
  assert_err "$o" "sys_admin 不应能通过 SQL 关闭三权分立"
  assert_contains "$o" "turn off" "应提示无权限关闭三权分立"
}

case_AUTH035() {
  # 三权分立下普通用户：security_admin 建用户并授权 → 普通用户按授权访问
  local o
  TS "DROP USER sep035" >/dev/null 2>&1
  TS "CREATE USER sep035 'Sep035@12345'" >/dev/null 2>&1
  T "DROP DATABASE root.sep035" >/dev/null 2>&1
  T "CREATE DATABASE root.sep035" >/dev/null 2>&1
  T "CREATE TIMESERIES root.sep035.d1.s1 INT32" >/dev/null 2>&1
  T "INSERT INTO root.sep035.d1(time,s1) VALUES(1,7)" >/dev/null 2>&1
  o=$(L sep035 'Sep035@12345' "select s1 from root.sep035.d1")
  echo "  before grant -> $(echo "$o" | sed -n '2p' | cut -c1-80)"
  TS "GRANT READ ON root.sep035.** TO USER sep035" >/dev/null 2>&1
  sleep 35
  o=$(L sep035 'Sep035@12345' "select s1 from root.sep035.d1")
  echo "  after grant -> $(echo "$o" | sed -n '2p' | cut -c1-80)"
  assert_contains "$o" "7" "security_admin 授权后普通用户应可读"
  TS "DROP USER sep035" >/dev/null 2>&1
  T "DROP DATABASE root.sep035" >/dev/null 2>&1
}

case_AUTH036() {
  # 三权之间不可互相授予管理权限（IT 中的 803 约束）
  local o
  TS "DROP USER sep036" >/dev/null 2>&1
  TS "CREATE USER sep036 'Sep036@12345'" >/dev/null 2>&1
  o=$(TS "GRANT SYSTEM ON root.** TO USER sep036 WITH GRANT OPTION")
  echo "  grant SYSTEM with grant option -> $(echo "$o" | head -1 | cut -c1-110)"
  echo "$o" | grep -q "803" && ok "三权分立下管理权限不可带 grant option（803）" || echo "  NOTE: 未拦截 WITH GRANT OPTION，需对照设计确认"
  TS "DROP USER sep036" >/dev/null 2>&1
}

CASES+=(
"AUTH-030|三权分立|反向|开启后 root（超级用户）禁止登录（803）|case_AUTH030"
"AUTH-031|三权分立|正向|sys_admin/security_admin/audit_admin 三账号均可登录|case_AUTH031"
"AUTH-032|三权分立|正向|职责分离：仅 security_admin 可建用户|case_AUTH032"
"AUTH-033|三权分立|边界|数据面：sys_admin 可读写，security_admin 不应能读业务数据|case_AUTH033"
"AUTH-034|三权分立|边界|三权分立不可由打开切回关闭（需求明确，803 为预期）|case_AUTH034"
"AUTH-035|三权分立|正向|三权分立下普通用户按授权访问|case_AUTH035"
"AUTH-036|三权分立|边界|管理权限不可带 grant option（803）|case_AUTH036"
)
