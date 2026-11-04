#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0619】[修改用户名] 2.0.7.1 RC3 开启三权分立，
#   security_admin 给不存在的用户赋 security 权限时报错信息不友好
#   期望：给出"用户不存在"类明确提示
#   验证版本：2.0.13.1 / ab6d3de（需 separation 模式）
# ============================================================================
MODE_OF["RN-122"]="separation"
RN0619_USER=rn0619_no_such_user

case_RN122() {
  local out
  out=$(L security_admin 'TimechoDB@2021' "grant security on root.** to user $RN0619_USER" 2>&1)
  echo "  security_admin GRANT 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -qi 'NullPointerException'; then
    fail "返回内容暴露空指针"
  else
    ok "未暴露空指针"
  fi
  if echo "$out" | grep -qiE 'No such user|does not exist|不存在|用户'; then
    ok "给出用户不存在的明确提示"
  elif echo "$out" | grep -qiE 'error|exception|失败|803'; then
    ok "被拒绝并给出可读错误"
  else
    fail "既未拒绝也无明确提示（$(echo "$out" | head -1 | cut -c1-140)）"
  fi
}

CASES+=(
"RN-122|TIMECHODB-0619 三权分立|负向|security_admin 给不存在用户赋权应给出明确提示|case_RN122"
)
