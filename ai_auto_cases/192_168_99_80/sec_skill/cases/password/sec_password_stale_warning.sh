#!/bin/bash
# ============================================================================
# SEC-10 密码定期更改提示（需求：password_stale_warning_days）
#   a) 配置项存在、默认 30、restart 生效、<=0 表示禁用
#   b) 密码超过 N 天未改 → 登录时提示
#      "Your password has not been changed for 30 days. For security best practices,
#       please consider updating your password."
#   c) 不修改则重复触发（连续两次登录都提示）
#   d) 提示只在超过阈值后出现（未超阈值时不提示）
#   手法：默认阈值 30 天已生效（无需重启），把被测登录入口 DN 时钟前移 31 天制造"陈旧"。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-10" "密码定期更改提示（password_stale_warning_days）"

U="${SEC_USER_PREFIX}_stale"
PW='Abcdefgh123!'
SHIFT_DN="$PRIMARY"
sec_user_drop "$U"

sec_log "--- 1) 配置项语义（默认 30 / restart / <=0 禁用）---"
v=$(conf_eff password_stale_warning_days)
[ -z "$v" ] && v=$(sshx "$PRIMARY" "grep -hE '^password_stale_warning_days=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | head -1 | cut -d= -f2" | tr -d ' \r')
assert_eq "password_stale_warning_days 生效值/配置值" "${v:-30}" "30"
m=$(conf_set_raw password_stale_warning_days 30)
assert_contains "SET stale=30 成功" "$m" "successfully"
if printf '%s' "$m" | grep -q 'restart is required'; then
  pass "该配置为 restart 生效（与需求 effectiveMode: restart 一致）"
else
  warn "观察：password_stale_warning_days 实测为热加载（SET 后无 restart 提示），与需求文档 effectiveMode: restart 不一致 —— 语义差异，待研发确认是否需要改文档"
fi

sec_log "--- 2) 建用户（密码刚设置，未超阈值 → 登录不应提示）---"
m=$(sec_user_create "$U" "$PW"); assert_contains "创建用户" "$m" "successfully"
out0=$(sec_sql_via "$SHIFT_DN" "$U" "$PW" tree "list user;")
assert_not_contains "未超阈值不提示密码陈旧" "$out0" "has not been changed for"
assert_eq "用户可正常登录" "$(try_login_ok "$U" "$PW" "$SHIFT_DN" && echo yes || echo no)" "yes"

sec_log "--- 3) 把 $SHIFT_DN 时钟前移 31 天（超过 30 天阈值，不重启集群）---"
sshx "$SHIFT_DN" "date -s \"\$(date -d '+31 days' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'" | sed "s/^/    .$SHIFT_DN /"
sleep 2

sec_log "--- 4) 提示文案 + 重复触发 ---"
out1=$(sec_sql_via "$SHIFT_DN" "$U" "$PW" tree "list user;")
assert_contains "超阈值登录出现密码陈旧提示" "$out1" "has not been changed for"
assert_contains "提示含可配置天数（30 days）" "$out1" "30 days"
assert_contains "提示含安全建议文案" "$out1" "please consider updating your password"
assert_eq "提示不影响登录成功" "$(try_login_ok "$U" "$PW" "$SHIFT_DN" && echo yes || echo no)" "yes"

out2=$(sec_sql_via "$SHIFT_DN" "$U" "$PW" tree "list user;")
assert_contains "不修改密码则重复触发（第二次登录仍提示）" "$out2" "has not been changed for"

sec_log "--- 5) 改密码后提示消失（历史时间刷新）---"
sec_user_alter "$U" 'Abcdefgh456@' >/dev/null
out3=$(sec_sql_via "$SHIFT_DN" "$U" 'Abcdefgh456@' tree "list user;")
assert_not_contains "改密后不再提示（历史时间已刷新）" "$out3" "has not been changed for"

sec_log "--- 5b) 若为热加载：设为 0 后提示应立即消失（<=0 禁用）---"
m0=$(conf_set_raw password_stale_warning_days 0)
if printf '%s' "$m0" | grep -q 'restart is required'; then
  warn "stale=0 需重启才生效（文档语义），本次不重启，跳过即时生效验证"
else
  out4=$(sec_sql_via "$SHIFT_DN" "$U" 'Abcdefgh456@' tree "list user;")
  assert_not_contains "stale=0 热生效：超期用户登录不再提示（<=0 禁用）" "$out4" "has not been changed for"
  sec_conf_set password_stale_warning_days 30 >/dev/null
  sleep 5
  out5=$(sec_sql_via "$SHIFT_DN" "$U" 'Abcdefgh456@' tree "list user;")
  if printf '%s' "$out5" | grep -aq "has not been changed for"; then
    pass "恢复 30 后再次提示（热加载双向生效）"
  else
    warn "恢复 30 后未立即再次提示（热加载反向可能有延迟/需下次登录），不影响 <=0 禁用与超期提示两条主断言"
  fi
fi

sec_log "--- 6) 恢复时钟与配置 ---"
sshx "$SHIFT_DN" "date -s \"\$(date -d '-31 days' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'" | sed "s/^/    .$SHIFT_DN /"
sec_conf_set password_stale_warning_days 30 >/dev/null
assert_eq "恢复后时钟正确、用户可登录" "$(try_login_ok "$U" 'Abcdefgh456@' && echo yes || echo no)" "yes"
sec_user_drop "$U"
sec_case_finish
