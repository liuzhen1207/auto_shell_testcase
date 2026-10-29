# Group 1: 基础身份鉴别（用户名/密码、用户管理、登录鉴权、权限、强密码基础）
# 依据：V1.0.0.1 身份鉴别功能-需求分析（identityAuthentication-001）、
#       V2.0.7.1 强安全级别密码-需求分析（a-d 复杂度）

case_AUTH001() {
  local o
  o=$(T "show cluster;")
  assert_ok "$o" "root 默认用户应可登录"
  echo "$o" | grep -q "Running" || fail "root 登录后 show cluster 无 Running 节点"
}

case_AUTH002() {
  local o
  o=$(L root 'WrongPass@123')
  assert_err "$o" "错误密码应登录失败"
  assert_code "$o" "801" "错误密码应返回 801 Authentication failed"
  assert_not_contains "$o" "WrongPass" "错误提示不得回显密码"
}

case_AUTH003() {
  local o
  o=$(L auth_nosuch_user 'Xyz@12345')
  assert_err "$o" "不存在的用户应登录失败"
  assert_code "$o" "804" "不存在用户返回 804（与 801 可区分 → 用户枚举风险，报告中记录）"
}

case_AUTH004() {
  T "DROP USER auth004" >/dev/null 2>&1
  local o
  o=$(T "CREATE USER auth004 'Auth004@12345'")
  assert_ok "$o" "创建用户应成功"
  o=$(L auth004 'Auth004@12345')
  assert_ok "$o" "新用户应可登录"
}

case_AUTH005() {
  T "DROP USER auth005" >/dev/null 2>&1
  T "CREATE USER auth005 'Auth005@12345'" >/dev/null
  local o
  o=$(T "ALTER USER auth005 SET PASSWORD 'Auth005@54321'")
  assert_ok "$o" "修改密码应成功"
  o=$(L auth005 'Auth005@12345')
  assert_err "$o" "旧密码应失效"
  o=$(L auth005 'Auth005@54321')
  assert_ok "$o" "新密码应可登录"
}

case_AUTH006() {
  T "DROP USER auth006" >/dev/null 2>&1
  T "CREATE USER auth006 'Auth006@12345'" >/dev/null
  local o
  o=$(T "DROP USER auth006")
  assert_ok "$o" "删除用户应成功"
  o=$(L auth006 'Auth006@12345')
  assert_err "$o" "已删除用户应无法登录"
}

case_AUTH007() {
  # 强密码：长度 + 复杂度过 a-d；本版本最小长度 12
  T "DROP USER auth007" >/dev/null 2>&1
  local o
  o=$(T "CREATE USER auth007 'NoSpecial123456'")
  assert_err "$o" "缺特殊字符应被拒"
  assert_code "$o" "820" "缺特殊字符应返回 820"
  o=$(T "CREATE USER auth007 'NoDigit@abcdefg'")
  assert_err "$o" "缺数字应被拒"
  o=$(T "CREATE USER auth007 'noupper@123456'")
  assert_err "$o" "缺大写应被拒"
  o=$(T "CREATE USER auth007 'Short@12345'")
  assert_err "$o" "长度不足 12 应被拒"
  assert_contains "$o" "length" "短密码应提示长度不足"
  o=$(T "CREATE USER auth007 'Good@1234567'")
  assert_ok "$o" "长度>=12 且四类字符齐全应通过"
  T "DROP USER auth007" >/dev/null 2>&1
}

case_AUTH008() {
  # 权限：未授权不能读，GRANT 后可读，REVOKE 后不可读
  T "DROP DATABASE root.auth008db" >/dev/null 2>&1
  T "CREATE DATABASE root.auth008db" >/dev/null
  T "CREATE TIMESERIES root.auth008db.d1.s1 INT32" >/dev/null
  T "INSERT INTO root.auth008db.d1(time,s1) VALUES(1,1)" >/dev/null
  T "DROP USER auth008" >/dev/null 2>&1
  T "CREATE USER auth008 'Auth008@12345'" >/dev/null
  local o
  o=$(L auth008 'Auth008@12345' "select s1 from root.auth008db.d1")
  echo "$o" | grep -q "Empty set" || fail "未授权用户应查不到数据（期望 Empty set，实际 $(echo "$o" | sed -n '2p')）"
  T "GRANT READ ON root.auth008db.** TO USER auth008" >/dev/null 2>&1
  sleep 2
  o=$(L auth008 'Auth008@12345' "select s1 from root.auth008db.d1")
  assert_contains "$o" "1" "授权后应可读"
  T "REVOKE READ ON root.auth008db.** FROM USER auth008" >/dev/null 2>&1
  sleep 2
  o=$(L auth008 'Auth008@12345' "select s1 from root.auth008db.d1")
  echo "$o" | grep -q "Empty set" || fail "回收权限后应查不到数据"
}

case_AUTH009() {
  local o
  o=$(T "LIST USER")
  assert_ok "$o" "LIST USER 应可执行"
  echo "$o" | grep -qiE "password|hash|sha|md5" && fail "LIST USER 暴露了密码相关字段"
}

case_AUTH010() {
  # 关闭强密码策略后，弱密码应可设置；随后恢复
  T "SET CONFIGURATION 'enforce_strong_password'='false'" >/dev/null 2>&1
  sleep 2
  T "DROP USER auth010" >/dev/null 2>&1
  local o
  o=$(T "CREATE USER auth010 'weakpassword'")
  assert_ok "$o" "关闭强密码策略后弱密码应可设置"
  o=$(L auth010 'weakpassword')
  assert_ok "$o" "弱密码用户应可登录"
  T "SET CONFIGURATION 'enforce_strong_password'='true'" >/dev/null 2>&1
  sleep 2
  T "DROP USER auth010" >/dev/null 2>&1
  o=$(T "CREATE USER auth010 'weakpassword'")
  assert_err "$o" "恢复策略后弱密码应再次被拒"
  T "DROP USER auth010" >/dev/null 2>&1
}

CASES+=(
"AUTH-001|基础鉴别|正向|root 默认用户登录与集群可用|case_AUTH001"
"AUTH-002|基础鉴别|反向|错误密码登录失败（801，不回显密码）|case_AUTH002"
"AUTH-003|基础鉴别|反向|不存在用户登录失败（804，与 801 可区分）|case_AUTH003"
"AUTH-004|用户管理|正向|CREATE USER 后新用户可登录|case_AUTH004"
"AUTH-005|用户管理|正向|ALTER USER SET PASSWORD 旧密码失效、新密码可用|case_AUTH005"
"AUTH-006|用户管理|反向|DROP USER 后无法登录|case_AUTH006"
"AUTH-007|强安全密码|边界|复杂度 a-d：缺特殊字符/数字/大写被拒，齐全通过|case_AUTH007"
"AUTH-008|授权|正向|未授权不可读、GRANT 后可读、REVOKE 后不可读|case_AUTH008"
"AUTH-009|用户管理|边界|LIST USER 不暴露密码/哈希|case_AUTH009"
"AUTH-010|强安全密码|边界|enforce_strong_password 热切换生效|case_AUTH010"
)
