#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1442 / 【TIMECHODB-0479】
#   drop user 成功后应断开该用户的连接；否则它仍可继续执行操作；
#   若再创建同名用户，这个“僵尸会话”还会复活。
#   期望：DROP USER 后原会话的下一次语句返回 802（会话失效）；
#         重建同名用户后，原会话仍失效（不复活），新连接可正常使用。
#
#   RC3 已含修复：ff2f6120b9 Add auto-log-out for stale/invalid sessions
#     - AuthOperationProcedure 关闭被删用户会话
#     - IoTDBStatement 遇到失效会话自动登出，报 802
#
#   验证版本：2.0.13.1 RC3 / ac7f95e
#   两个独立用例，各自要求干净集群环境（由 tools/run_case_clean.sh 保证）：
#     RN-211 普通模式（root 管理用户）
#     RN-212 三权分立（security_admin 管理用户，root 被禁）
# ============================================================================
RN1442_USER=rn1442_u
RN1442_PW='Rn1442@123456'
RN1442_PROBE=tools/user_session_probe.sh

_rn1442_assert() {  # $1=adminUser $2=adminPw $3=tag
  local admin="$1" adminpw="$2" tag="$3" out
  out=$(bash "$BASE/$RN1442_PROBE" "$admin" "$adminpw" "$RN1442_USER" "$RN1442_PW" 2>&1)
  echo "$out" | sed 's/^/    /'

  assert_contains "$out" "USER_CREATED=true" "$tag 创建用户 $RN1442_USER"
  assert_contains "$out" "USER_CONNECTED=true" "$tag 用户登录成功"
  assert_contains "$out" "BEFORE_DROP=QUERY_OK" "$tag drop 前该连接可正常执行"
  assert_contains "$out" "DROPPED=true" "$tag DROP USER 成功"
  assert_contains "$out" "AFTER_DROP_STALE=true" "$tag drop 后原连接执行被拒（802 会话失效）"
  assert_not_contains "$out" "AFTER_DROP=QUERY_OK" "$tag drop 后原连接不应继续可执行"
  assert_contains "$out" "RECREATED=true" "$tag 重建同名同密码用户成功"
  assert_contains "$out" "AFTER_RECREATE_STALE=true" "$tag 重建后原（僵尸）连接仍失效"
  assert_not_contains "$out" "AFTER_RECREATE_OLD_SESSION=QUERY_OK" "$tag 僵尸会话未复活"
  assert_contains "$out" "NEW_SESSION_OK=true" "$tag 重建后新连接可正常执行"
  assert_contains "$out" "CLEANUP=true" "$tag 清理用户"
}

case_RN211() {
  echo "  --- 普通模式：DROP USER 断连与僵尸会话不复活 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    fail "当前不是普通模式（root 被禁），无法执行 RN-211"
    return
  fi
  ok "当前为普通模式（root 可登录）"
  _rn1442_assert root 'TimechoDB@2021' "[普通]"
}

case_RN212() {
  echo "  --- 三权分立：DROP USER 断连与僵尸会话不复活 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    ok "当前已是三权分立（root 被拒 803）"
  else
    ( cd "$BASE" && NEW="$NEW" bash tools/mode.sh on ) > /tmp/rn1442_mode_on.log 2>&1
    if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
      ok "三权分立已开启：root 被拒（803）"
    else
      fail "开启三权分立后 root 仍可登录"
      return
    fi
  fi
  if L security_admin 'TimechoDB@2021' "list user" 2>&1 | grep -q "UserId\|Total line"; then
    ok "security_admin 可登录（list user 正常）"
  else
    fail "security_admin 登录失败：$(L security_admin 'TimechoDB@2021' "list user" 2>&1 | head -1 | cut -c1-120)"
    return
  fi
  _rn1442_assert security_admin 'TimechoDB@2021' "[三权分立]"
}

CASES+=(
"RN-211|TDB-1442 DROP USER 断连（普通模式）|异常|drop user 后原会话执行返回 802；重建同名用户后僵尸会话不复活，新连接正常|case_RN211"
"RN-212|TDB-1442 DROP USER 断连（三权分立）|异常|三权分立下 security_admin 删用户同样断连且僵尸不复活|case_RN212"
)
