#!/bin/bash
# ============================================================================
# SEC-05 password_reuse_interval_days（需求 g：历史口令在 N 天内不得重用）
#
#   两级判定（2026-11-16 与用户确认的标准，避免误报）：
#     硬门禁（FAIL）：① 默认/禁用（-1，或 conf 无该键）时必须**无限制**（A→B→A 成功）
#                     ② =1 时窗口内**必须拒绝**（文案含 used recently / cannot be reused before）
#                     ③ 禁用后**必须恢复**可重用（-1）
#     柔性检查（WARN 不 FAIL）：显式 `=0` —— 需求写"0=无历史约束"，但产品把 0 改写为 1 天
#                     （CommonConfig.java:3428）。是否算缺陷待研发确认，故只记录不判失败。
#   说明：不使用 conf 写 0 的方式做"禁用"，避免污染环境（统一用 -1）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-05" "历史口令不可重用（默认无限制 / =1 窗口内拒绝 / 显式 0 柔性检查）"

U="${SEC_USER_PREFIX}_reuse"
PA='Abcdefgh123!'
PB='Abcdefgh456@'
PC='Abcdefgh789#'
PD='Abcdefgh000$'
sec_user_drop "$U"
# 每个相位都重建用户，避免上一相位的密码历史污染下一相位（实测踩过：A→B 撞上历史 B）
fresh(){ sec_user_drop "$U"; sec_user_create "$U" "$PA" >/dev/null; }

# ---------- 硬门禁 1：禁用（-1）时必须无限制 ----------
sec_log "--- 1) 禁用状态（-1，等价于 conf 无该键）→ A→B→A 必须成功 ---"
sec_conf_set password_reuse_interval_days -1 >/dev/null
rv=$(sec_conf_get password_reuse_interval_days)
[ -z "$rv" ] && rv="(不列出)"
sec_log "  当前 reuse 生效值=$rv"
fresh; assert_eq "相位1 用户已重建（密码 A）" "$(sec_login_ok "$U" "$PA" && echo yes || echo no)" "yes"
m=$(sec_user_alter "$U" "$PB"); assert_contains "A→B 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PA")
assert_contains "禁用状态下 B→A 允许（无历史约束，硬门禁）" "$m" "successfully"

# ---------- 柔性检查：显式 0 的语义（需求 0=无约束 vs 实现 0→1 天） ----------
sec_log "--- 2) 显式 =0 的语义（需求：无约束；实现：被改写为 1 天）—— 仅记录，不判 FAIL ---"
m=$(sec_conf_set password_reuse_interval_days 0); assert_contains "设置 =0 被接受" "$m" "successfully"
sleep 1
fresh; m=$(sec_user_alter "$U" "$PB"); assert_contains "相位2 A→B 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PA")
if printf '%s' "$m" | grep -q 'successfully'; then
  pass "显式 =0 时 B→A 允许（与需求一致）"
else
  warn "显式 =0 时 B→A 被拒（实现把 0 改写为 1 天，CommonConfig.java:3428；需求为 0=无约束）—— 已记录为待确认偏差，不判 FAIL：$(printf '%s' "$m" | cut -c1-150)"
fi

# ---------- 硬门禁 2：=1 时窗口内必须拒绝 ----------
sec_log "--- 3) =1：窗口内 B→A 必须被拒（硬门禁）---"
m=$(sec_conf_set password_reuse_interval_days 1); assert_contains "设置 =1 被接受" "$m" "successfully"
assert_eq "生效值=1（热加载）" "$(sec_conf_get password_reuse_interval_days)" "1"
fresh; assert_eq "相位3 用户已重建" "$(sec_login_ok "$U" "$PA" && echo yes || echo no)" "yes"
m=$(sec_user_alter "$U" "$PB"); assert_contains "A→B 成功（B 为当前密码）" "$m" "successfully"
# 当前密码是 B；尝试改回 A（A 在历史里，且时间很近）
m=$(sec_user_alter "$U" "$PA")
assert_contains "=1 时 B→A 被拒（硬门禁）" "$m" "cannot be reused before"
assert_contains "复用文案含 used recently" "$m" "used recently"
assert_eq "被拒后当前密码仍是 B" "$(sec_login_ok "$U" "$PB" && echo yes || echo no)" "yes"

sec_log "--- 4) 多条历史：C→B、C→A 均被拒；全新密码放行（硬门禁）---"
fresh; m=$(sec_user_alter "$U" "$PB"); assert_contains "相位4 A→B 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PC"); assert_contains "B→C 成功" "$m" "successfully"
m=$(sec_user_alter "$U" "$PB"); assert_contains "C→B 被拒（历史 B）" "$m" "cannot be reused before"
m=$(sec_user_alter "$U" "$PA"); assert_contains "C→A 被拒（历史 A）" "$m" "cannot be reused before"
m=$(sec_user_alter "$U" "$PD"); assert_contains "C→全新密码 成功" "$m" "successfully"

# ---------- 硬门禁 3：禁用后必须恢复 ----------
sec_log "--- 5) 回到禁用（-1）后必须恢复可重用（硬门禁）---"
sec_conf_set password_reuse_interval_days -1 >/dev/null
m=$(sec_user_alter "$U" "$PA")
assert_contains "禁用后 C→A 允许（恢复无限制）" "$m" "successfully"

sec_log "--- 6) 窗口'过后可重用'（=1 且间隔已过）由 SEC-06 覆盖（时钟偏移）---"
warn "本用例验证 禁用无限制 / =1 窗口内拒绝 / 恢复；'窗口过后可重用'见 SEC-06"

sec_conf_set password_reuse_interval_days -1 >/dev/null
sec_user_drop "$U"
sec_case_finish
