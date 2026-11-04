#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0618】开启三权分立后，security_admin 修改用户名失败：
#   701 Unsupported author type（DN 日志 handleAccountUnlock 路径抛出）
#   期望：security_admin 可以正常修改用户名
#   验证版本：2.0.13.1 / ab6d3de（需 separation 模式）
#   说明：不重命名内置账号，改用普通用户验证同一代码路径，避免破坏内置账号
# ============================================================================
MODE_OF["RN-125"]="separation"
RN0618_USER=rn0618_u1
RN0618_NEW=rn0618_u2
RN0618_PW='Rn0618@123456'

case_RN125() {
  local out
  # 用 security_admin 创建并改名（security_admin 口令见 auth_skill 约定）
  out=$(L security_admin 'TimechoDB@2021' "create user $RN0618_USER '$RN0618_PW'")
  echo "  创建用户：$(echo "$out" | head -1 | cut -c1-130)"

  out=$(L security_admin 'TimechoDB@2021' "alter user $RN0618_USER rename to $RN0618_NEW")
  echo "  改名返回：$(echo "$out" | head -1 | cut -c1-170)"

  if echo "$out" | grep -qi 'Unsupported author type'; then
    fail "仍报 701 Unsupported author type（缺陷未修复）"
  else
    ok "不再报 701 Unsupported author type"
  fi
  if echo "$out" | grep -qiE 'success'; then
    ok "security_admin 改名成功"
  else
    fail "改名未成功（$(echo "$out" | head -1 | cut -c1-120)）"
  fi

  # 清理
  L security_admin 'TimechoDB@2021' "drop user $RN0618_NEW" >/dev/null 2>&1
  L security_admin 'TimechoDB@2021' "drop user $RN0618_USER" >/dev/null 2>&1
}

CASES+=(
"RN-125|TIMECHODB-0618 三权分立|功能|security_admin 应能修改用户名（不再 701 Unsupported author type）|case_RN125"
)
