#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0670】[2.0.7.1] 不开三权分立时，给普通用户设置
#   最小连接数报 NPE（User.getName() because "<local12>" is null）
#   验证版本：2.0.13.1 / ab6d3de（当前集群 enable_separation_of_powers=false）
#   判据：create user + ALTER USER ... SET MAX/MIN_SESSION_PER_USER 全部成功，无 NPE/无 301
# ============================================================================
RN0670_USER=rn0670_u
RN0670_PW='Rn0670@123456'

case_RN107() {
  local out sep
  sep=$(T "show variables" 2>/dev/null | grep -i 'separation' | head -2)
  echo "  当前模式：$(echo "$sep" | tr '\n' ' ' | cut -c1-120)"

  T "drop user $RN0670_USER" >/dev/null 2>&1
  out=$(T "create user $RN0670_USER '$RN0670_PW'")
  assert_ok "$out" "创建普通用户"

  out=$(T "alter user $RN0670_USER set max_session_per_user 2")
  echo "  SET MAX: $(echo "$out" | head -1 | cut -c1-140)"
  if echo "$out" | grep -qiE 'NullPointerException|NPE|301|already exists'; then
    fail "设置 MAX_SESSION_PER_USER 报异常（$(echo "$out" | head -1 | cut -c1-100)）"
  else
    assert_ok "$out" "设置 MAX_SESSION_PER_USER 成功"
  fi

  out=$(T "alter user $RN0670_USER set min_session_per_user 1")
  echo "  SET MIN: $(echo "$out" | head -1 | cut -c1-140)"
  if echo "$out" | grep -qiE 'NullPointerException|NPE|301|already exists'; then
    fail "设置 MIN_SESSION_PER_USER 报异常（$(echo "$out" | head -1 | cut -c1-100)）"
  else
    assert_ok "$out" "设置 MIN_SESSION_PER_USER 成功"
  fi

  out=$(T "create user $RN0670_USER '$RN0670_PW'")
  if echo "$out" | grep -qi 'already exists'; then
    ok "用户确实存在（重复创建报 already exists）"
  else
    fail "无法确认用户存在（重复创建返回 $(echo "$out" | head -1 | cut -c1-100)）"
  fi

  T "drop user $RN0670_USER" >/dev/null 2>&1
}

CASES+=(
"RN-107|TIMECHODB-0670 连接数限制|功能|不开三权分立时设置 MAX/MIN_SESSION_PER_USER 不报 NPE|case_RN107"
)
