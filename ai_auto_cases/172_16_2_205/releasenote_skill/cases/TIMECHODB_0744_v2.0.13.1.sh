#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0744】[V2.0.7.1-三权分立] 三权分立关闭时，
#   超级管理员授予普通用户 SYSTEM 权限后，未获转授权限的普通用户
#   仍可以给其他用户授予 SYSTEM 权限（越权，预期应被拒绝并提示）
#   验证版本：2.0.13.1 / ab6d3de（当前 enable_separation_of_powers=false）
#   判据：user1 无 grant option，执行 grant system ... to user test_user1 必须被拒绝
# ============================================================================
RN0744_U1=rn0744_u1
RN0744_U2=rn0744_u2
RN0744_PW='Rn0744@123456'

case_RN109() {
  local out grant
  T "drop user $RN0744_U2" >/dev/null 2>&1
  T "drop user $RN0744_U1" >/dev/null 2>&1

  assert_ok "$(T "create user $RN0744_U1 '$RN0744_PW'")" "创建 user1"
  assert_ok "$(T "create user $RN0744_U2 '$RN0744_PW'")" "创建 user2"
  assert_ok "$(T "grant system on root.** to user $RN0744_U1")" "root 授予 user1 SYSTEM（无 grant option）"

  # user1 尝试把 SYSTEM 转授给 user2 —— 应被拒绝
  grant=$(L "$RN0744_U1" "$RN0744_PW" "grant system on root.** to user $RN0744_U2")
  echo "  越权转授返回：$(echo "$grant" | head -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$grant" | grep -qi 'success'; then
    fail "user1 无转授权限却成功把 SYSTEM 授予他人（越权）"
  else
    ok "转授被拒绝"
  fi
  if echo "$grant" | grep -qiE 'grant option|permission|privilege|803|权限'; then
    ok "拒绝信息含权限相关提示"
  else
    fail "拒绝信息不明确（实际 $(echo "$grant" | head -1 | cut -c1-140)）"
  fi

  # 对照：root（有 grant option）转授应成功
  out=$(T "grant system on root.** to user $RN0744_U2")
  assert_ok "$out" "对照：root 转授成功"

  T "drop user $RN0744_U2" >/dev/null 2>&1
  T "drop user $RN0744_U1" >/dev/null 2>&1
}

CASES+=(
"RN-109|TIMECHODB-0744 权限越权|安全|无 grant option 的普通用户不得把 SYSTEM 转授他人|case_RN109"
)
