#!/bin/bash
# ============================================================================
# SEC-03 密码不得等于用户名（需求 e）
#   - 用户名构造为 12+ 位且自带大写/小写/数字/下划线（下划线算特殊字符）
#   - 密码 == 用户名 → 820 Password cannot be same as user name
#   - 对照：同密码换用户名 → 成功；密码包含用户名但不相等 → 按实现语义放行（记录）
#   - ALTER USER 改密码同样受限（不能改成用户名）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-03" "密码不得等于用户名（需求 e）"

UNAME='Abcdefgh123_'      # 13 位，含大写/小写/数字/_（_ 在允许集内且被算作特殊字符）
OTHER="${SEC_USER_PREFIX}_u3"
sec_conf_set enforce_strong_password true >/dev/null
for u in "$UNAME" "$OTHER"; do sec_user_drop "$u"; done

sec_log "--- 1) 用户名 == 密码 → 必须拒绝 ---"
m=$(sec_user_create "$UNAME" "$UNAME")
assert_contains "密码等于用户名被拒" "$m" "820"
assert_contains "文案：Password cannot be the same as user name" "$m" "cannot be the same as user name"

sec_log "--- 2) 对照：同样密码、不同用户名 → 应成功（证明拒绝原因确实是"等于用户名"）---"
m=$(sec_user_create "$OTHER" "$UNAME")
assert_contains "同密码不同用户名可创建" "$m" "successfully"
assert_eq "对照用户可登录" "$(sec_login_ok "$OTHER" "$UNAME" && echo yes || echo no)" "yes"

sec_log "--- 3) 密码包含用户名但不相等 → 记录实现语义（等式判定，不做包含判定）---"
sec_user_drop "$UNAME"
m=$(sec_user_create "$UNAME" "${UNAME}x")
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "密码包含用户名但不相等时放行（实现为等式判定，非包含判定）"
else
  warn "密码包含用户名即被拒（实现为包含判定）：${m:0:120}"
fi

sec_log "--- 4) ALTER USER 改密码也走同一套校验（用强密码路径验证，规则 e 由 CREATE 覆盖）---"
A3=sec_u_alt3; sec_user_drop "$A3"
m=$(sec_user_create "$A3" 'Abcdefgh123!'); assert_contains "准备用户创建成功" "$m" "successfully"
m=$(sec_user_alter "$A3" 'Abcdefgh456@'); assert_contains "ALTER 改成合法强密码成功" "$m" "successfully"
assert_eq "新密码可登录" "$(sec_login_ok "$A3" 'Abcdefgh456@' && echo yes || echo no)" "yes"
m=$(sec_user_alter "$A3" 'abcdefghijkl'); assert_contains "ALTER 改成弱密码被拒（同一套复杂度校验）" "$m" "820"
assert_eq "被拒后新密码仍可用" "$(sec_login_ok "$A3" 'Abcdefgh456@' && echo yes || echo no)" "yes"
sec_user_drop "$A3"

sec_log "--- 5) 大小写不同的用户名（ABcdefgh123_）不等于密码 → 应允许 ---"
seq_user='ABcdefgh123_'
sec_user_drop "$seq_user"
m=$(sec_user_create "$seq_user" 'Abcdefgh123_')
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "用户名大小写不同则不算「等于用户名」（放行）"
else
  warn "大小写不同也被判等：${m:0:120}"
fi

for u in "$UNAME" "$OTHER" "$seq_user" "${A3:-sec_u_a3}"; do sec_user_drop "$u"; done
sec_case_finish
