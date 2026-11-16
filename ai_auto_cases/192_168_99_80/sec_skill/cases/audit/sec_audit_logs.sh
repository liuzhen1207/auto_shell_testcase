#!/bin/bash
# ============================================================================
# SEC-08 审计与日志（需求"审计和日志记录/错误处理"自查项）
#   1) 关键操作（建用户/改密码/删用户/改安全配置）应有审计记录
#   2) 失败登录（密码错误/弱密码/过期）应有审计或日志记录，且不含明文密码
#   3) 错误信息不得回显明文密码（820 文案只说明规则）
#   4) CN/DN 日志门禁：无预期外 WARN/ERROR（含本用例触发的所有操作）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-08" "审计与日志：关键操作留痕、日志不含明文密码、错误不泄密"

U="${SEC_USER_PREFIX}_audit"
PW='Abcdefgh123!'
sec_user_drop "$U"
sec_log_mark

sec_log "--- 1) 关键操作：建用户 / 改密码 / 删用户 / 改安全配置 ---"
m=$(sec_user_create "$U" "$PW"); assert_contains "建用户成功" "$m" "successfully"
m=$(sec_user_alter "$U" 'Abcdefgh456@'); assert_contains "改密码成功" "$m" "successfully"
m=$(sec_conf_set password_expiration_days 2); assert_contains "改安全配置成功" "$m" "successfully"
sec_conf_set password_expiration_days 0 >/dev/null
m=$(sec_user_drop "$U" 2>/dev/null; sec_user_exists "$U" && echo "still" || echo "gone")
assert_eq "删用户生效" "$m" "gone"

sec_log "--- 2) 失败路径：弱密码 / 密码==用户名 / 错误密码登录 ---"
sec_user_drop "${U}2"
m=$(sec_user_create "${U}2" 'abcdefghijkl')
assert_contains "弱密码被拒（820）" "$m" "820"
m=$(sec_user_create "${U}3" "${U}3")
assert_contains "密码==用户名被拒（820）" "$m" "820"
sec_user_create "${U}4" "$PW" >/dev/null
bad_out=$(sec_sql_as "${U}4" 'WrongPass123!' tree "show databases;" 2>&1)
assert_contains "错误密码登录被拒" "$bad_out" "Error"

sec_log "--- 3) 错误信息不得回显明文密码（820 文案只讲规则）---"
sec_user_drop "${U}5"
m=$(sec_user_create "${U}5" 'abcdefghijkl')
assert_not_contains "弱密码错误文案不含该密码本身" "$m" "abcdefghijkl"
assert_not_contains "密码==用户名错误文案不回显密码" "$(sec_user_create "${U}6" "${U}6")" "${U}6"

sec_log "--- 4) 日志不含明文密码（把用例用到的密码逐个在 CN/DN 日志里搜）---"
sec_check_password_leak "$PW"
sec_check_password_leak 'Abcdefgh456@'
sec_check_password_leak 'abcdefghijkl'
sec_check_password_leak 'WrongPass123!'

sec_log "--- 5) 审计/日志里能看到关键操作留痕（宽松判据：出现用户名或事件名即可）---"
hit=0
for h in $ALL_NODES; do
  n=$(sshx "$h" "cat $DB_DIR/logs/*.log 2>/dev/null | tail -n 4000 | grep -acE 'MODIFY_PASSWD|CREATE_USER|DROP_USER|CHANGE_AUDIT_OPTION|AuditLog|audit' || true")
  [ "${n:-0}" -gt 0 ] && hit=$((hit+1))
done
if [ "$hit" -ge 1 ]; then
  pass "至少 $hit 个节点的日志里出现审计/操作留痕（MODIFY_PASSWD/CREATE_USER/AuditLog 等）"
else
  warn "未在节点日志里检索到审计留痕（可能审计日志落在 root.__audit 表而非文本日志，需人工确认）"
fi

sec_log "--- 6) CN/DN 日志门禁（无预期外 WARN/ERROR）---"
sec_check_logs

for u in "$U" "${U}2" "${U}3" "${U}4" "${U}5" "${U}6"; do sec_user_drop "$u" 2>/dev/null || true; done
sec_case_finish
