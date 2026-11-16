#!/bin/bash
# ============================================================================
# SEC-05 password_reuse_interval_days（需求 g：历史口令在 N 天内不得重用）
#   - 默认 0：不限制（A→B→A 应允许）
#   - =1：A→B 成功后立即 B→A 应被拒，文案 "The password has been used recently, and it cannot be reused before <时间>"
#   - 多条历史：A→B→C 后 C→B、C→A 都应被拒；全新密码放行
#   - 窗口"过后"可重用：由 SEC-06 在同一轮时钟前移里验证
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-05" "历史口令不可重用（password_reuse_interval_days，需求 g）"

U="${SEC_USER_PREFIX}_reuse"
PA='Abcdefgh123!'
PB='Abcdefgh456@'
PC='Abcdefgh789#'
PD='Abcdefgh000$'
sec_user_drop "$U"

sec_log "--- 1) 默认值应为 0（无历史约束）---"
assert_eq "默认 password_reuse_interval_days" "$(sec_conf_get password_reuse_interval_days)" "0"

sec_log "--- 2) reuse=0：A→B→A 允许 ---"
m=$(sec_user_create "$U" "$PA"); assert_contains "创建用户（A）" "$m" "successfully"
m=$(sec_user_alter "$U" "$PB"); assert_contains "A→B 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PA")
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "reuse=0 时 B→A 允许（无历史约束）"
else
  # 若被拒：说明 DN 仍按非 0 的旧值判定（配置热加载不一致），记录为偏差证据
  fail "reuse=0 时 B→A 仍被拒（疑似 DN 侧按旧值判定）：${m:0:170}"
fi

sec_log "--- 3) reuse=1：B→A 立即重用应被拒 ---"
m=$(sec_conf_set password_reuse_interval_days 1); assert_contains "设置 reuse=1 被接受" "$m" "successfully"
assert_eq "生效值=1（热加载）" "$(sec_conf_get password_reuse_interval_days)" "1"
m=$(sec_user_alter "$U" "$PB"); assert_contains "A→B 成功（B 为当前密码）" "$m" "successfully"
m=$(sec_user_alter "$U" "$PA")
assert_contains "B→A 立即重用被拒" "$m" "cannot be reused before"
assert_contains "复用文案含 used recently" "$m" "used recently"
assert_eq "被拒后当前密码仍是 B" "$(sec_login_ok "$U" "$PB" && echo yes || echo no)" "yes"

sec_log "--- 4) 多条历史：A→B→C 后 C→B、C→A 均被拒，全新密码放行 ---"
m=$(sec_user_alter "$U" "$PC"); assert_contains "B→C 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PB"); assert_contains "C→B 被拒（历史 B）" "$m" "cannot be reused before"
m=$(sec_user_alter "$U" "$PA"); assert_contains "C→A 被拒（历史 A）" "$m" "cannot be reused before"
m=$(sec_user_alter "$U" "$PD"); assert_contains "C→全新密码 成功" "$m" "successfully"

sec_log "--- 5) 边界：reuse 设为 0 后立即可重用（配置即时生效）---"
sec_conf_set password_reuse_interval_days 0 >/dev/null
assert_eq "reuse 已回 0" "$(sec_conf_get password_reuse_interval_days)" "0"
m=$(sec_user_alter "$U" "$PA")
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "reuse=0 后立即可以重用历史密码 A"
else
  fail "reuse 回 0 后仍拒绝重用（配置未即时生效）：${m:0:170}"
fi

sec_log "--- 6) 窗口过后可重用：见 SEC-06（时钟前移专项，避免重复起停集群）---"
warn "本用例只验证窗口内不可重用；窗口过后可重用由 SEC-06 覆盖"

sec_conf_set password_reuse_interval_days 0 >/dev/null
sec_user_drop "$U"
sec_case_finish
