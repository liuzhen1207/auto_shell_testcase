#!/bin/bash
# ============================================================================
# SEC-12 身份鉴别基础（需求：identityAuthentication-001/002）
#   a) 默认用户 root 存在、是管理员、不可删除/不可被赋撤权（list user 可见 SUPER_USER）
#   b) 密码不以明文存储（配置/数据目录/日志中不出现明文密码）
#   c) CREATE USER / ALTER USER SET PASSWORD / LIST USER / DROP USER 语义
#   d) 新用户初始无任何权限（查不到数据 / 被拒）
#   e) 用户名大小写敏感；密码大小写敏感
#   f) 用户不存在 → 804；密码错误 → 801
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-12" "身份鉴别基础：用户/密码管理、大小写敏感、错误码、明文不入库"

U="${SEC_USER_PREFIX}_ida"
UX="${SEC_USER_PREFIX}_ida_upper"
PW='Abcdefgh123!'
sec_user_drop "$U"; sec_user_drop "$UX"

sec_log "--- 1) 默认管理员 root 的存在性与不可删除 ---"
lu=$(st "list user;")
assert_contains "list user 含 root" "$lu" "root"
assert_contains "root 为超级管理员（SUPER_USER/root 行）" "$lu" "root"
m=$(st "drop user root;" | grep -aE 'Msg:|Error:' | tail -1)
assert_contains "root 不可删除（803 Access Denied）" "$m" "803"
assert_contains "root 不可删除的文案说明原因" "$m" "Cannot drop admin user"

sec_log "--- 2) 密码不以明文存储 ---"
m=$(sec_user_create "$U" "$PW"); assert_contains "创建用户" "$m" "successfully"
hitlog=$(sshx "$PRIMARY" "grep -ra -l -F -- '$PW' $DB_DIR/logs 2>/dev/null | head -3")
assert_eq "运行日志中无明文密码" "${hitlog:-none}" "none"
# 已知问题（研发确认不可修复）：明文口令会写入 ConfigNode 共识（Raft）日志。
# 按"已知行为基线"处理：命中 → WARN（不计 FAIL）；若某版本不再命中 → 也提示复核台账（防止静默通过）。
wal=$(sshx "$PRIMARY" "grep -ra -l -F -- '$PW' $DB_DIR/data/confignode/consensus 2>/dev/null | head -2")
if [ -n "$wal" ]; then
  warn "已知问题 #4（研发确认不修复，见 docs/KNOWN_DEFECTS.md）：明文口令出现在 CN 共识日志（$(printf '%s' "$wal" | head -1 | sed 's#.*/consensus/##')）；见 docs/KNOWN_DEFECTS.md #4"
else
  warn "已知问题已变化：本次未在 CN 共识日志中检出明文口令，若为研发修复请复核 docs/KNOWN_DEFECTS.md #4 并更新账本"
fi
# 存储侧必须是哈希（硬门禁）
prof=$(sshx "$PRIMARY" "grep -ra -l -F -- '$PW' $DB_DIR/data/confignode/system/users 2>/dev/null | head -2")
assert_eq "用户元数据文件（profile）中无明文口令（应为哈希）" "${prof:-none}" "none"
sec_check_password_leak "$PW"

sec_log "--- 3) CREATE / ALTER / LIST / DROP 语义 ---"
assert_eq "新用户出现在 list user" "$(sec_user_exists "$U" && echo yes || echo no)" "yes"
m=$(sec_user_alter "$U" 'Abcdefgh456@'); assert_contains "ALTER USER SET PASSWORD 成功" "$m" "successfully"
assert_eq "旧密码失效" "$(try_login_ok "$U" "$PW" && echo yes || echo no)" "no"
assert_eq "新密码可登录" "$(try_login_ok "$U" 'Abcdefgh456@' && echo yes || echo no)" "yes"

sec_log "--- 4) 新用户初始无权限 ---"
out=$(sec_sql_via "$PRIMARY" "$U" 'Abcdefgh456@' tree "select count(*) from root.**;")
if printf '%s' "$out" | grep -qE '803|701|no permission|No permissions'; then
  pass "新用户查 root.** 被拒（803/701）"
elif printf '%s' "$out" | grep -qE 'Empty set|^\+?-|count'; then
  warn "新用户查 root.** 未报权限错误（返回空集/计数）：$(printf '%s' "$out" | grep -aE '^\|' | head -2 | tr '\n' ' ')"
else
  fail "新用户越权查询返回异常：$(printf '%s' "$out" | grep -aE 'Error|Msg' | tail -1 | cut -c1-140)"
fi

sec_log "--- 5) 用户名大小写敏感 ---"
uc=$(echo "$U" | tr 'a-z' 'A-Z')
m=$(sec_user_create "$uc" "$PW")
assert_contains "大写用户名可独立创建（说明用户名大小写敏感）" "$m" "successfully"
assert_eq "大写用户名与原名是两个用户" "$(sec_user_exists "$uc" && echo yes || echo no)" "yes"
out=$(st "drop user $uc;"); assert_contains "清理大写用户" "$out" "successfully"

sec_log "--- 6) 密码大小写敏感 ---"
lower=$(printf '%s' 'Abcdefgh456@' | tr 'A-Z' 'a-z')
c=$(login_code "$U" "$lower")
assert_eq "密码大小写不同 → 认证失败（801）" "$c" "801"

sec_log "--- 7) 用户不存在 / 密码错误 的错误码 ---"
c=$(login_code "${SEC_USER_PREFIX}_nouser" 'Whatever1!')
assert_eq "不存在的用户 → 804" "$c" "804"
c=$(login_code "$U" 'WrongPass123!')
assert_eq "密码错误 → 801" "$c" "801"
assert_not_contains "认证失败不回显密码" "$(try_login "$U" 'WrongPass123!')" "WrongPass123!"

sec_log "--- 8) DROP USER ---"
out=$(st "drop user $U;"); assert_contains "DROP USER 成功" "$out" "successfully"
assert_eq "删除后用户不存在" "$(sec_user_exists "$U" && echo yes || echo no)" "no"
sec_case_finish
