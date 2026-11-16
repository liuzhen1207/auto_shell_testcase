#!/bin/bash
# ============================================================================
# SEC-01 密码长度上下限（需求 a；**即使关闭 enforce_strong_password 也生效**）
#   11/12/32/33 字符边界；空串；超长
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-01" "密码长度上下限（12~32，无条件生效）"

U1="${SEC_USER_PREFIX}_len"
PW11='Abcdefgh12!'          # 11
PW12='Abcdefgh123!'         # 12
PW32="Abcdefgh123!$(printf 'A%.0s' $(seq 1 20))"   # 12 + 20 = 32
PW33="Abcdefgh123!$(printf 'A%.0s' $(seq 1 21))"   # 12 + 21 = 33
for p in "$PW11" "$PW12" "$PW32" "$PW33"; do :; done
[ ${#PW11} -eq 11 ] || warn "PW11 长度=${#PW11}（期望 11）"
[ ${#PW12} -eq 12 ] || warn "PW12 长度=${#PW12}（期望 12）"
[ ${#PW32} -eq 32 ] || warn "PW32 长度=${#PW32}（期望 32）"
[ ${#PW33} -eq 33 ] || warn "PW33 长度=${#PW33}（期望 33）"

sec_log "--- 1) enforce_strong_password=true 下的长度边界 ---"
sec_conf_set enforce_strong_password true >/dev/null
assert_eq "enforce_strong_password 生效值" "$(sec_conf_get enforce_strong_password)" "true"

sec_user_drop "$U1"
m=$(sec_user_create "$U1" "$PW11"); assert_contains "11 字符被拒（>=12）" "$m" "820"
assert_contains "11 字符文案" "$m" "must be greater than or equal to 12"

m=$(sec_user_create "$U1" "$PW33"); assert_contains "33 字符被拒（<=32）" "$m" "820"
assert_contains "33 字符文案" "$m" "must be less than or equal to 32"

m=$(sec_user_create "$U1" "$PW12"); assert_contains "12 字符（下边界）创建成功" "$m" "successfully"
sec_user_drop "$U1"
m=$(sec_user_create "$U1" "$PW32"); assert_contains "32 字符（上边界）创建成功" "$m" "successfully"
# 32 位密码能真实登录（证明不是只放过校验）
assert_eq "32 位密码可登录" "$(sec_login_ok "$U1" "$PW32" && echo yes || echo no)" "yes"
sec_user_drop "$U1"

sec_log "--- 2) enforce_strong_password=false 时，长度仍必须生效（需求明确）---"
sec_conf_set enforce_strong_password false >/dev/null
assert_eq "enforce_strong_password 已关闭" "$(sec_conf_get enforce_strong_password)" "false"
m=$(sec_user_create "$U1" "$PW11"); assert_contains "关闭强密码后 11 字符仍被拒" "$m" "820"
m=$(sec_user_create "$U1" "$PW33"); assert_contains "关闭强密码后 33 字符仍被拒" "$m" "820"
m=$(sec_user_create "$U1" "$PW12"); assert_contains "关闭强密码后 12 字符可建" "$m" "successfully"
sec_user_drop "$U1"

sec_log "--- 3) 空密码/极短 ---"
m=$(sec_user_create "$U1" ""); assert_contains "空密码被拒" "$m" "820"
m=$(sec_user_create "$U1" "a"); assert_contains "1 字符被拒" "$m" "820"

sec_conf_set enforce_strong_password true >/dev/null
sec_user_drop "$U1"
sec_case_finish
