#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0678】[三权分立] security_admin 执行
#   list privileges of user <who_is_not_exist> 返回
#   301: Failed to connect to config node，且 CN 打空指针
#   期望：给出明确"用户不存在"类错误，不报 301，不打 NPE
#   验证版本：2.0.13.1 / ab6d3de（需 separation 模式）
# ============================================================================
MODE_OF["RN-121"]="separation"
RN0678_USER=rn0678_no_such_user
RN0678_PW='Rn0678@123456'

case_RN121() {
  local out
  # 用 security_admin 执行（默认口令见 auth_skill）
  out=$(L security_admin 'TimechoDB@2021' "list privileges of user $RN0678_USER" 2>&1)
  echo "  security_admin 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -q '301'; then
    fail "仍返回 301 Failed to connect to config node"
  else
    ok "不再返回 301"
  fi
  if echo "$out" | grep -qi 'NullPointerException\|allPath is null'; then
    fail "返回内容暴露空指针细节"
  else
    ok "未暴露 NPE 细节"
  fi
  if echo "$out" | grep -qiE 'No such user|does not exist|不存在|用户'; then
    ok "给出用户不存在的明确提示"
  else
    fail "提示不明确（实际 $(echo "$out" | head -1 | cut -c1-140)）"
  fi
}

CASES+=(
"RN-121|TIMECHODB-0678 三权分立|负向|security_admin 查询不存在用户权限应给出明确提示而非 301|case_RN121"
)
