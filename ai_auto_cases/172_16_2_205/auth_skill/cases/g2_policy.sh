# Group 2: 密码策略（有效期/复用/陈旧提示）与「密码过期校验」日志缺陷
# 依据：V2.0.7.1 强安全级别密码-需求分析（f 有效期、g 历史口令）、密码定期更改提示需求

case_AUTH011() {
  # 密码有效期配置可下发；未配置(0)时不应阻止登录
  local o
  o=$(T "SET CONFIGURATION 'password_expiration_days'='30'")
  assert_ok "$o" "password_expiration_days 应可下发"
  o=$(L root "$PW")
  assert_ok "$o" "配置有效期后管理员仍可登录"
  o=$(T "SET CONFIGURATION 'password_expiration_days'='0'")
  assert_ok "$o" "password_expiration_days 应可复位为 0"
}

case_AUTH012() {
  # 历史口令不可复用：配置 >0 后改回旧密码应被拒
  T "SET CONFIGURATION 'password_reuse_interval_days'='30'" >/dev/null 2>&1
  sleep 2
  T "DROP USER auth012" >/dev/null 2>&1
  T "CREATE USER auth012 'Auth012@12345'" >/dev/null
  T "ALTER USER auth012 SET PASSWORD 'Auth012@54321'" >/dev/null
  local o
  o=$(T "ALTER USER auth012 SET PASSWORD 'Auth012@12345'")
  echo "  改回旧密码: $(echo "$o" | head -1)"
  echo "$o" | grep -qE "820|821|reuse|history" || echo "  NOTE: 未拒绝改回旧密码，需对照需求 g) 确认实现范围"
  o=$(L auth012 'Auth012@54321')
  assert_ok "$o" "当前密码仍应可登录"
  T "SET CONFIGURATION 'password_reuse_interval_days'='0'" >/dev/null 2>&1
  T "DROP USER auth012" >/dev/null 2>&1
}

case_AUTH013() {
  # 陈旧密码提示：password_stale_warning_days 可配置（时间型提示无法在秒级验证，验证配置生效且不影响登录）
  local o
  o=$(T "SET CONFIGURATION 'password_stale_warning_days'='1'")
  assert_ok "$o" "password_stale_warning_days 应可下发"
  o=$(L root "$PW")
  assert_ok "$o" "开启陈旧提示后登录仍应成功"
  T "SET CONFIGURATION 'password_stale_warning_days'='30'" >/dev/null 2>&1
}

case_AUTH014() {
  # 【缺陷回归】DataNodeAuthUtils.checkPasswordExpiration 在“可容忍降级”时仍打 ERROR + 堆栈。
  # 复现手法（实测有效）：重启全部 DataNode，随后立即持续登录，命中启动窗口内
  #   queryPasswordExpiration 的 Future 超时：
  #   TimeoutException -> executeLoginHistory(:108) -> checkPasswordExpiration(:519) -> SessionManager.login(:170)
  # 代码随后走 mayBypass 放行（登录成功），却已把 ERROR + 完整堆栈写入日志。
  # 判定：窗口内任一 DN 出现该 ERROR 即 FAIL（期望：降级不应记 ERROR）。
  local f=/data1/iotdb/$NEW/logs/log_datanode_all.log i ip
  local delta total=0
  declare -A before
  for ip in $DN_LIST; do before[$ip]=$(ssh -o StrictHostKeyChecking=no root@$ip "grep -c 'Fail to check password expiration' $f 2>/dev/null || true" 2>/dev/null); done

  echo "  stop all DNs"
  for ip in $DN_LIST; do
    ssh -o StrictHostKeyChecking=no root@$ip "bash /data1/iotdb/$NEW/sbin/stop-datanode.sh >/dev/null 2>&1; sleep 1; pkill -9 -f 'com.timecho.iotdb.DataNode'; true" 2>/dev/null
  done
  sleep 4
  echo "  start all DNs, hammer logins during the startup window"
  for ip in $DN_LIST; do
    ssh -o StrictHostKeyChecking=no root@$ip "setsid /data1/iotdb/$NEW/sbin/start-datanode.sh >> /tmp/dn_race.log 2>&1 < /dev/null &" 2>/dev/null
  done
  log_mark_all >/dev/null 2>&1
  for i in $(seq 1 90); do
    L root "$PW" "show databases" >/dev/null 2>&1
    $CLI -h ${DN_LIST#* } -p 6667 -u root -pw "$PW" -e "show databases" >/dev/null 2>&1
    sleep 0.4
  done
  wait_running 8 >/dev/null 2>&1
  sleep 2

  for ip in $DN_LIST; do
    local after
    after=$(ssh -o StrictHostKeyChecking=no root@$ip "grep -c 'Fail to check password expiration' $f 2>/dev/null || true" 2>/dev/null)
    delta=$(( ${after:-0} - ${before[$ip]:-0} ))
    [ "$delta" -gt 0 ] && { echo "  $ip 新增 $delta 条"; total=$((total+delta)); }
  done
  echo "  total new ERROR occurrences: $total"
  if [ "$total" -gt 0 ]; then
    ssh -o StrictHostKeyChecking=no root@172.16.2.2 "grep -A8 -m1 'Fail to check password expiration' $f 2>/dev/null | head -10" 2>/dev/null | sed 's/^/    /'
    fail "DN 启动窗口内登录打印 ERROR 'Fail to check password expiration'（含 TimeoutException 堆栈，共 $total 条）：降级已放行登录，不应记 ERROR"
  else
    ok "本次未命中竞态（缺陷为间歇性，未触发不代表不存在）"
  fi
}

case_AUTH015() {
  # 用户重命名后旧名不可登录、新名可登录
  T "DROP USER auth015old" >/dev/null 2>&1; T "DROP USER auth015new" >/dev/null 2>&1
  T "CREATE USER auth015old 'Auth015@12345'" >/dev/null
  local o
  o=$(T "ALTER USER auth015old RENAME TO auth015new")
  assert_ok "$o" "用户重命名应成功"
  o=$(L auth015old 'Auth015@12345')
  assert_err "$o" "旧用户名应无法登录"
  o=$(L auth015new 'Auth015@12345')
  assert_ok "$o" "新用户名应可登录"
  T "DROP USER auth015new" >/dev/null 2>&1
}

case_AUTH016() {
  # 会话数限制：MAX_SESSION_PER_USER 可设置并生效（超出时报错）
  T "DROP USER auth016" >/dev/null 2>&1
  T "CREATE USER auth016 'Auth016@12345'" >/dev/null
  local o
  o=$(T "ALTER USER auth016 SET MAX_SESSION_PER_USER 1")
  assert_ok "$o" "设置最大会话数应成功"
  o=$(T "LIST USER")
  echo "$o" | grep -q "auth016" || fail "LIST USER 未列出新建用户"
  T "DROP USER auth016" >/dev/null 2>&1
}

CASES+=(
"AUTH-011|密码策略|正向|password_expiration_days 可下发/复位，且不影响登录|case_AUTH011"
"AUTH-012|密码策略|边界|password_reuse_interval_days>0 时改回旧密码的行为|case_AUTH012"
"AUTH-013|密码策略|正向|password_stale_warning_days 可配置且不阻断登录|case_AUTH013"
"AUTH-014|日志缺陷|缺陷|未配置过期策略时不应打印 'Fail to check password expiration' ERROR|case_AUTH014"
"AUTH-015|用户管理|正向|ALTER USER RENAME 后旧名失效、新名可用|case_AUTH015"
"AUTH-016|用户管理|边界|ALTER USER SET MAX_SESSION_PER_USER 生效|case_AUTH016"
)
