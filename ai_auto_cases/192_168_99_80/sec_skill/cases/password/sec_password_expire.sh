#!/bin/bash
# ============================================================================
# SEC-06 密码有效期（需求 f）+ 过期提示条件
#   手法：只把被测登录入口 DN（.77）时钟前移 2 天，其它节点保持正确时间 →
#     1) 过期用户经 .77 登录被拒并给出 ALTER USER 文案
#     2) 同一用户经 .78（时钟正确）仍可登录 ⇒ 记录"过期判定依赖 DN 本地时钟"的观察
#     3) 恢复 .77 时钟后恢复正常
#   另覆盖：默认 0、热加载、int64 溢出（极大 expiry）不提示
#   说明：CLI 不回显 openSession 的 "Your password will expire at ..."（只写 warning chain），
#         3 天提示的可见性用 WARN 记录，不在此判 FAIL。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-06" "密码有效期（单 DN 时钟偏移法）+ 提示条件"

U="${SEC_USER_PREFIX}_exp"
PA='Abcdefgh123!'
PB='Abcdefgh456@'
SHIFT_DN="${PRIMARY}"
CTRL_DN=$(echo $DN_NODES | tr ' ' '\n' | grep -v "^$SHIFT_DN$" | head -1)
sec_user_drop "$U"

sec_log "--- 0) 默认值与前置 ---"
assert_eq "默认 password_expiration_days" "$(sec_conf_get password_expiration_days)" "0"
m=$(sec_user_create "$U" "$PA"); assert_contains "用户创建成功" "$m" "successfully"
assert_eq "用户当前可登录（$CTRL_DN）" "$(sec_login_ok_via "$CTRL_DN" "$U" "$PA" && echo yes || echo no)" "yes"

sec_log "--- 1) 热加载 expiry=2（不重启）---"
m=$(sec_conf_set password_expiration_days 2); assert_contains "expiry=2 设置成功" "$m" "successfully"
assert_eq "生效值=2" "$(sec_conf_get password_expiration_days)" "2"

sec_log "--- 2) 只把 $SHIFT_DN 时钟前移 3 天（其余节点不动，集群不重启）---"
cur_epoch=$(sshx "$SHIFT_DN" "date +%s" | tr -dc '0-9')
sshx "$SHIFT_DN" "date -s \"\$(date -d '+3 days' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'"
new_epoch=$(sshx "$SHIFT_DN" "date +%s" | tr -dc '0-9')
skew=$(( (new_epoch - cur_epoch) / 86400 ))
assert_eq "该 DN 已前移天数" "$skew" "3"

sec_log "--- 3) 过期用户经 $SHIFT_DN 登录应被拒 + 文案 ---"
msg=$(sec_login_msg_via "$SHIFT_DN" "$U" "$PA")
assert_contains "过期登录被拒（820 + Password has expired）" "$msg" "Password has expired"
assert_contains "文案提示用 ALTER USER 改密" "$msg" 'ALTER USER'
assert_eq "确实登不进去" "$(sec_login_ok_via "$SHIFT_DN" "$U" "$PA" && echo yes || echo no)" "no"

sec_log "--- 4) 同一用户经 $CTRL_DN（时钟正确）仍可登录 → 记录时钟依赖 ---"
if sec_login_ok_via "$CTRL_DN" "$U" "$PA"; then
  warn "观察：过期判定依赖 DN 本地时钟 —— $SHIFT_DN 判过期、$CTRL_DN 仍可登录（节点时钟偏差时结论不一致）"
else
  pass "两节点一致判为过期（不依赖单节点时钟）"
fi

sec_log "--- 5) 改密码后经时钟正确的节点可登录（$CTRL_DN）---"
m=$(sec_user_alter_via "$CTRL_DN" "$U" "$PB")
assert_contains "经 $CTRL_DN 改密码成功" "$m" "successfully"
assert_eq "新密码可登录（$CTRL_DN）" "$(sec_login_ok_via "$CTRL_DN" "$U" "$PB" && echo yes || echo no)" "yes"

sec_log "--- 6) int64 溢出：expiry 设极大值 → 不提示过期时间 ---"
sec_conf_set password_expiration_days 2147483647 >/dev/null
msgb=$(sec_login_msg_via "$CTRL_DN" "$U" "$PB")
assert_not_contains "极大 expiry 不提示 will expire at" "$msgb" "will expire at"

sec_log "--- 7) 恢复 $SHIFT_DN 时钟与配置 ---"
sshx "$SHIFT_DN" "date -s \"\$(date -d '-3 days' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'" | sed "s/^/    /"
sec_conf_set password_expiration_days 0 >/dev/null
assert_eq "恢复后用户可登录（$SHIFT_DN）" "$(sec_login_ok_via "$SHIFT_DN" "$U" "$PB" && echo yes || echo no)" "yes"
sec_user_drop "$U"
sec_case_finish
