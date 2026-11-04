#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0632】[tree] select * from root.__audit.password_history._0
#   能看到密码明文，且显示格式与其他用户不同
#   期望：口令历史中不出现明文口令
#   验证版本：2.0.13.1 / ab6d3de
#   判据：对新用户改一次口令后，查询其 password_history，输出中不得出现明文口令串
# ============================================================================
RN0632_USER=rn0632_u
RN0632_PW1='Rn0632@Old1234'
RN0632_PW2='Rn0632@New5678'

case_RN124() {
  local out uid hist
  T "drop user $RN0632_USER" >/dev/null 2>&1
  assert_ok "$(T "create user $RN0632_USER '$RN0632_PW1'")" "创建用户（旧口令）"
  assert_ok "$(T "alter user $RN0632_USER set password '$RN0632_PW2'")" "修改口令（触发 password_history）"

  uid=$(T "list user" 2>/dev/null | awk -F'|' -v u="$RN0632_USER" '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($3==u) print $2}' | head -1)
  echo "  UserId=$uid"
  if [ -z "$uid" ]; then
    fail "未能从 list user 解析出 UserId"
    T "drop user $RN0632_USER" >/dev/null 2>&1
    return 1
  fi

  hist=$(T "select * from root.__audit.password_history._$uid")
  echo "  password_history 记录行数：$(echo "$hist" | grep -c '^|20')"

  if echo "$hist" | grep -qF "$RN0632_PW1" || echo "$hist" | grep -qF "$RN0632_PW2"; then
    fail "password_history 中出现明文口令（缺陷未修复）"
  else
    ok "password_history 未出现明文口令"
  fi

  T "drop user $RN0632_USER" >/dev/null 2>&1
}

CASES+=(
"RN-124|TIMECHODB-0632 口令安全|安全|password_history 不应出现明文口令|case_RN124"
)
