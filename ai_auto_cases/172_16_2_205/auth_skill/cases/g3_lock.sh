# Group 3: 防止口令暴力破解 + 客户端侧（本组最后执行，会触发 IP 级锁定，结束后重启 DN 清除）
# 依据：V2.0.7.1 防止口令暴力破解-需求分析/技术设计、客户端隐去明文密码、连接失败不返回 IP 端口

case_AUTH017() {
  T "DROP USER auth017" >/dev/null 2>&1
  T "CREATE USER auth017 'Auth017@12345'" >/dev/null
  local i o
  for i in 1 2 3 4 5; do
    o=$(L auth017 "Bad@$i")
    echo "  bad#$i -> $(echo "$o" | head -1 | cut -c1-80)"
  done
  o=$(L auth017 'Auth017@12345')
  echo "  correct after 5 failures -> $(echo "$o" | head -1 | cut -c1-100)"
  assert_code "$o" "822" "连续失败达阈值后应锁定（822 Account is blocked）"
}

case_AUTH018() {
  # 锁定期间换一个用户（不同用户、同一 IP）验证是否为 IP 级限制
  T "DROP USER auth018" >/dev/null 2>&1
  T "CREATE USER auth018 'Auth018@12345'" >/dev/null 2>&1 || echo "  NOTE: 建用户也受影响（IP 已锁）"
  local o
  o=$(L auth018 'Auth018@12345')
  echo "  other user during lock -> $(echo "$o" | head -1 | cut -c1-100)"
  echo "$o" | grep -q "822" && echo "  NOTE: 锁定按 IP 生效（同 IP 其他用户也被拒）" || echo "  NOTE: 锁定按用户生效（同 IP 其他用户可用）"
}

case_AUTH019() {
  # 手动解锁语句可执行（ALTER USER ... ACCOUNT UNLOCK）
  local o
  o=$(T "ALTER USER auth017 ACCOUNT UNLOCK")
  assert_ok "$o" "ALTER USER ... ACCOUNT UNLOCK 应可执行"
  o=$(L auth017 'Auth017@12345')
  echo "  after unlock -> $(echo "$o" | head -1 | cut -c1-100)"
  if echo "$o" | grep -q "822"; then
    echo "  NOTE: 手动 UNLOCK 未解除 IP 级锁定（IP 计数仍在内存中）"
  else
    ok "解锁后可登录"
  fi
}

case_AUTH020() {
  # 重启 DN 后锁定状态应清除（内存计数）：自带造锁步骤，保证可独立执行
  T "DROP USER auth020" >/dev/null 2>&1
  T "CREATE USER auth020 'Auth020@12345'" >/dev/null 2>&1
  local i o
  for i in 1 2 3 4 5; do L auth020 "Bad@$i" >/dev/null 2>&1; done
  o=$(L auth020 'Auth020@12345')
  echo "  locked before restart -> $(echo "$o" | head -1 | cut -c1-90)"
  echo "  restart DN 172.16.2.2"
  restart_dn 172.16.2.2 || fail "DN 重启后集群未恢复 8 节点"
  # 重启必然产生选主/拉配置类 ERROR，重置日志标记，只统计重启之后的噪声
  log_mark_all >/dev/null 2>&1
  o=$(L auth020 'Auth020@12345')
  echo "  after DN restart -> $(echo "$o" | head -1 | cut -c1-90)"
  assert_ok "$o" "重启 DN 后锁定应解除，正确密码可登录"
  T "DROP USER auth020" >/dev/null 2>&1
}

case_AUTH021() {
  # 连接失败信息不应包含 IP/端口
  local o
  o=$($CLI -h 172.16.2.2 -p 16667 -u root -pw "$PW" -e "show databases" 2>&1)
  echo "  connect wrong port -> $(echo "$o" | head -2 | tr '\n' ' ' | cut -c1-140)"
  assert_err "$o" "错误端口应连接失败"
  echo "$o" | grep -qE "172\.16\.2\.2:16667|16667" && fail "错误信息暴露了 IP/端口（需求：连接失败不返回 IP 端口信息）" || ok "错误信息未暴露 IP:端口"
}

case_AUTH022() {
  # 客户端不回显明文密码（-pw 参数不出现在标准输出的提示里）
  local o
  o=$($CLI -h 172.16.2.2 -p 6667 -u root -pw "$PW" -e "show databases" 2>&1)
  assert_ok "$o" "带密码参数登录应成功"
  echo "$o" | grep -q "$PW" && fail "客户端输出中出现了明文密码" || ok "输出中无明文密码"
}

CASES+=(
"AUTH-017|暴力破解|正向|连续 5 次密码错误后账号/IP 锁定（822）|case_AUTH017"
"AUTH-018|暴力破解|边界|锁定范围为 IP 级还是用户级（记录）|case_AUTH018"
"AUTH-019|暴力破解|正向|ALTER USER ... ACCOUNT UNLOCK 可执行并观察解锁效果|case_AUTH019"
"AUTH-020|暴力破解|可靠性|重启 DN 后锁定状态清除|case_AUTH020"
"AUTH-021|客户端|反向|连接失败信息不含 IP/端口|case_AUTH021"
"AUTH-022|客户端|边界|客户端输出不回显明文密码|case_AUTH022"
)
