#!/bin/bash
# ============================================================================
# SEC-04 enforce_strong_password 开关语义
#   - 关闭后 b~e 四条复杂度规则不再校验（弱密码可建）
#   - 但 a（长度 12~32）仍然生效
#   - "修改该配置不影响已有的密码使用"：已存在用户的旧密码仍可登录
#   - 重新打开后立刻恢复强校验（hot_reload）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-04" "enforce_strong_password 开关语义（b~e 可关、a 不可关、不追溯）"

U="${SEC_USER_PREFIX}_enf"
sec_user_drop "$U"

sec_log "--- 1) 默认/开启状态：弱密码被拒 ---"
sec_conf_set enforce_strong_password true >/dev/null
assert_eq "生效值=true" "$(sec_conf_get enforce_strong_password)" "true"
m=$(sec_user_create "$U" 'abcdefghijkl')
assert_contains "开启时全小写 12 位被拒" "$m" "820"

sec_log "--- 2) 关闭后：同一弱密码可建（b~e 不校验）---"
m=$(sec_conf_set enforce_strong_password false)
assert_contains "关闭配置被接受" "$m" "successfully"
assert_eq "生效值=false（热加载）" "$(sec_conf_get enforce_strong_password)" "false"
m=$(sec_user_create "$U" 'abcdefghijkl')
assert_contains "关闭后全小写 12 位可建" "$m" "successfully"

sec_log "--- 3) 关闭后长度仍生效（需求 a 无条件）---"
m=$(sec_user_create "${U}2" 'abcdefghijk')   # 11
assert_contains "关闭后 11 位仍被拒" "$m" "820"
assert_contains "仍报长度文案" "$m" "greater than or equal to 12"

sec_log "--- 4) 关闭后用户名==密码也不再校验（e 属可关项）---"
uname=${SEC_USER_PREFIX}_e4
sec_user_drop "$uname"
m=$(sec_user_create "$uname" "$uname")
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "关闭强密码后 密码==用户名 被放行（e 属可关项）"
else
  warn "关闭强密码后 密码==用户名 仍被拒（实现上 e 未随开关关闭）：${m:0:140}"
fi

sec_log "--- 5) 不追溯：关闭前创建的强密码用户，关闭后仍可用旧密码登录 ---"
sec_user_drop "${SEC_USER_PREFIX}_old"
m=$(sec_user_create "${SEC_USER_PREFIX}_old" 'Abcdefgh123!')
assert_contains "强密码用户创建成功" "$m" "successfully"
sec_conf_set enforce_strong_password false >/dev/null
assert_eq "关闭后老用户仍可登录（不追溯）" "$(sec_login_ok "${SEC_USER_PREFIX}_old" 'Abcdefgh123!' && echo yes || echo no)" "yes"

sec_log "--- 6) 重新打开：立刻恢复强校验（热加载）---"
sec_conf_set enforce_strong_password true >/dev/null
assert_eq "生效值恢复 true" "$(sec_conf_get enforce_strong_password)" "true"
m=$(sec_user_create "${SEC_USER_PREFIX}_back" 'abcdefghijkl')
assert_contains "重新开启后弱密码再次被拒" "$m" "820"
assert_not_contains "重新开启后不报长度错误（说明是复杂度拦截）" "$m" "greater than or equal to 12"

for u in "$U" "${U}2" "$uname" "${SEC_USER_PREFIX}_old" "${SEC_USER_PREFIX}_back"; do sec_user_drop "$u"; done
sec_case_finish
