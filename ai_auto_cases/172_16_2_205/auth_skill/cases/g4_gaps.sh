# Group 4: 需求缺口补充（强密码 e 条款、最大长度、大小写、特权账户豁免等）
# 依据：V2.0.7.1 强安全级别密码-需求分析 a)~g)、防止口令暴力破解-需求分析（特权账户豁免）

case_AUTH023() {
  # 复杂度 b：缺小写字母应被拒
  TS "DROP USER auth023" >/dev/null 2>&1
  local o
  o=$(TS "CREATE USER auth023 'NOLOWER@12345'")
  echo "  缺小写 -> $(echo "$o" | head -1 | cut -c1-110)"
  echo "$o" | grep -qE "820|lower" || echo "  NOTE: 未拒绝缺小写密码（需求 b 未强制）"
  TS "DROP USER auth023" >/dev/null 2>&1
}

case_AUTH024() {
  # 需求 e：密码不能是用户标识/用户名
  TS "DROP USER auth024" >/dev/null 2>&1
  local o
  o=$(TS "CREATE USER auth024 'Auth024@12345'")
  assert_ok "$o" "前置：正常强密码可创建"
  o=$(TS "ALTER USER auth024 SET PASSWORD 'auth024'")
  echo "  改密码为用户名 -> $(echo "$o" | head -1 | cut -c1-110)"
  echo "$o" | grep -qE "820|user name|username" || echo "  NOTE: 未拒绝“密码等于用户名”（需求 e 未强制）"
  TS "DROP USER auth024" >/dev/null 2>&1
}

case_AUTH025() {
  # 需求 a：最大长度限制（无上限时记录观察）
  TS "DROP USER auth025" >/dev/null 2>&1
  local long pw i o
  pw="Aa1@"
  for i in $(seq 1 60); do pw="${pw}abcdefghij"; done   # 244 字符
  o=$(TS "CREATE USER auth025 '$pw'")
  echo "  244 字符密码 -> $(echo "$o" | head -1 | cut -c1-110)"
  if echo "$o" | grep -qE "820|length"; then
    ok "超长密码被拒绝（存在最大长度限制）"
  else
    echo "  NOTE: 未拒绝 244 字符密码（需求 a 的“最大长度”未见限制）"
  fi
  TS "DROP USER auth025" >/dev/null 2>&1
}

case_AUTH026() {
  # 特权账户豁免：root 连续多次错误密码后仍可登录（文档：root 与三权分立后的安全管理员本机豁免）
  local i o
  for i in 1 2 3 4 5 6; do L root "Bad@$i" >/dev/null 2>&1; done
  o=$(L root "$PW")
  echo "  root after 6 bad attempts -> $(echo "$o" | head -2 | tr '\n' ' ' | cut -c1-100)"
  assert_ok "$o" "root 应豁免暴力破解锁定（文档明确特权账户豁免）"
}

case_AUTH027() {
  # 空密码 / 纯空格等边界应被拒
  TS "DROP USER auth027" >/dev/null 2>&1
  local o
  o=$(TS "CREATE USER auth027 ''")
  echo "  空密码 -> $(echo "$o" | head -1 | cut -c1-110)"
  assert_err "$o" "空密码应被拒绝"
  o=$(TS "CREATE USER auth027 '           '")
  echo "  全空格密码 -> $(echo "$o" | head -1 | cut -c1-110)"
  assert_err "$o" "全空格密码应被拒绝"
  TS "DROP USER auth027" >/dev/null 2>&1
}

CASES+=(
"AUTH-023|强安全密码|边界|复杂度 b：缺小写字母应被拒|case_AUTH023"
"AUTH-024|强安全密码|边界|需求 e：密码不能等于用户名|case_AUTH024"
"AUTH-025|强安全密码|边界|需求 a：密码最大长度限制|case_AUTH025"
"AUTH-026|暴力破解|边界|特权账户（root）豁免锁定|case_AUTH026"
"AUTH-027|用户管理|反向|空密码/全空格密码应被拒|case_AUTH027"
)
