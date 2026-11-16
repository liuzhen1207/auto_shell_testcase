#!/bin/bash
# ============================================================================
# SEC-07 三个安全配置项的默认值 / 热加载 / 权限控制（含三权分立职责）
#   - 默认：enforce_strong_password=true、password_expiration_days=0、password_reuse_interval_days=0
#   - hot_reload：SET CONFIGURATION 后无需重启即生效（读回值 + 行为都变）
#   - 权限：需要 SECURITY 权限；三权分立下只有 security_admin 可改，sys_admin 不可；
#           root 在三权分立下不允许登录（803）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-07" "安全配置默认值/热加载/SECURITY 权限（含三权分立职责）"

sec_log "--- 1) 三个配置项的默认值（模板与生效值）---"
assert_eq "enforce_strong_password 默认 true" "$(sec_conf_get enforce_strong_password)" "true"
assert_eq "password_expiration_days 默认 0" "$(sec_conf_get password_expiration_days)" "0"
assert_eq "password_reuse_interval_days 默认 0" "$(sec_conf_get password_reuse_interval_days)" "0"

sec_log "--- 2) 热加载：改值后立刻读回（不重启）---"
sec_conf_set password_expiration_days 7 >/dev/null
assert_eq "expiry 热加载读回 7" "$(sec_conf_get password_expiration_days)" "7"
sec_conf_set password_expiration_days 0 >/dev/null
assert_eq "expiry 热加载读回 0" "$(sec_conf_get password_expiration_days)" "0"

sec_log "--- 3) 热加载的行为证据：关闭强密码后弱密码立刻可建（不重启）---"
sec_conf_set enforce_strong_password false >/dev/null
m=$(sec_user_create "${SEC_USER_PREFIX}_hot" 'abcdefghijkl')
assert_contains "关闭后（不重启）弱密码立刻可建" "$m" "successfully"
sec_conf_set enforce_strong_password true >/dev/null
m=$(sec_user_create "${SEC_USER_PREFIX}_hot2" 'abcdefghijkl')
assert_contains "重新开启后（不重启）立刻被拒" "$m" "820"
sec_user_drop "${SEC_USER_PREFIX}_hot"; sec_user_drop "${SEC_USER_PREFIX}_hot2"

sec_log "--- 4) 权限：security_admin 可改；sys_admin 不可改（三权分立职责边界）---"
if [ "$SEC_MODE" = "sep" ]; then
  # root 不允许登录
  out=$(sec_sql_as root "$ROOT_PW" tree "show cluster;")
  assert_contains "三权分立下 root 登录被拒（803）" "$out" "SUPER USER is not allowed to login"

  # sys_admin 改安全配置应被拒
  out=$(printf 'set sql_dialect=tree;\nset configuration %s=%s;\n' "'password_expiration_days'" "'5'" \
        | timeout 60 "$CLI" -h "$PRIMARY" -u "$SYS_ADMIN" -pw "$ADMIN_PW" 2>&1)
  last=$(printf '%s' "$out" | grep -aE 'Msg:|Error:' | tail -1)
  if printf '%s' "$last" | grep -qE '803|No permissions'; then
    pass "sys_admin 修改 password_expiration_days 被拒（803 需 SECURITY）"
  else
    fail "sys_admin 修改 password_expiration_days 未被拒：${last:0:160}"
  fi

  # security_admin 改成功（已由本用例其他步骤证明）
  assert_eq "security_admin 可改（生效值被本用例改过）" "$(sec_conf_get password_expiration_days)" "0"
else
  sec_log "  normal 模式：root 通管，无三权分立职责边界（该维度由 sep 模式覆盖）"
  out=$(sec_sql_as root "$ROOT_PW" tree "show cluster;")
  assert_contains "normal 模式 root 可登录" "$out" "Running"
fi

sec_log "--- 5) 非 SECURITY 普通用户改安全配置应被拒 ---"
U="${SEC_USER_PREFIX}_perm"
sec_user_drop "$U"
m=$(sec_user_create "$U" 'Abcdefgh123!'); assert_contains "普通用户创建成功" "$m" "successfully"
out=$(printf 'set sql_dialect=tree;\nset configuration %s=%s;\n' "'password_expiration_days'" "'9'" \
      | timeout 60 "$CLI" -h "$PRIMARY" -u "$U" -pw 'Abcdefgh123!' 2>&1)
last=$(printf '%s' "$out" | grep -aE 'Msg:|Error:' | tail -1)
if printf '%s' "$last" | grep -qE '803|No permissions'; then
  pass "普通用户修改安全配置被拒（803 需 SECURITY）"
else
  fail "普通用户修改安全配置未被拒：${last:0:160}"
fi
assert_eq "配置未被普通用户改动" "$(sec_conf_get password_expiration_days)" "0"
sec_user_drop "$U"

sec_case_finish
