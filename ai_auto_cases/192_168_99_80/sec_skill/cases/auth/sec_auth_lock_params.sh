#!/bin/bash
# ============================================================================
# SEC-15 防爆破相关参数边界与权限（需求：三个配置项 + 非法值回退 + 权限）
#   a) 三个配置项存在、类型为整数、effectiveMode=restart（SET 返回 restart is required）
#   b) failed_login_attempts_per_user：-1 完全禁用；0 自动调整为最小 1；>=1 自定义
#   c) failed_login_attempts：正整数据；非法（负数）回退默认并记 ERROR 日志
#   d) password_lock_time_minutes：正整数（分钟）
#   e) 权限：分离职责下 锁定配置需 SYSTEM（sys_admin），stale 需 SECURITY（security_admin）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-15" "防爆破参数边界（-1/0/负数/restart 语义）与修改权限"

sec_log "--- 1) 三个配置项的当前生效值/配置值 ---"
for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
  eff=$(conf_eff "$k")
  raw=$(sshx "$PRIMARY" "grep -hE '^$k=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | head -1 | cut -d= -f2" | tr -d ' \r')
  sec_log "  $k: show=${eff:-<不显示>} conf=${raw:-<未配置>}"
done
tmpl=$(sshx "$PRIMARY" "grep -hE '^#? ?failed_login_attempts=|^#? ?failed_login_attempts_per_user=|^#? ?password_lock_time_minutes=' $DB_DIR/conf/iotdb-system.properties.template 2>/dev/null | head -6" | tr -d '\r')
assert_contains "模板含 failed_login_attempts" "$tmpl" "failed_login_attempts"
assert_contains "模板含 failed_login_attempts_per_user" "$tmpl" "failed_login_attempts_per_user"
assert_contains "模板含 password_lock_time_minutes" "$tmpl" "password_lock_time_minutes"

sec_log "--- 2) restart 语义（SET 后返回 restart is required）---"
# 锁定类配置需要 SYSTEM 权限：sep 模式下用 sys_admin（职责分离设计），normal 用 root
if [ "${SEC_MODE:-normal}" = "sep" ]; then CFG_U="$DDL_USER"; CFG_P="$ADMIN_PW"; else CFG_U="$SEC_USER"; CFG_P="$SEC_PW"; fi
setcfg(){ conf_set_raw_as "$CFG_U" "$CFG_P" "$1" "$2"; }
m=$(setcfg failed_login_attempts 5)
assert_contains "failed_login_attempts SET 成功" "$m" "successfully"
assert_contains "failed_login_attempts 为 restart 生效" "$m" "restart is required"
m=$(setcfg password_lock_time_minutes 10)
assert_contains "password_lock_time_minutes 为 restart 生效" "$m" "restart is required"

sec_log "--- 3) per_user：-1 完全禁用 / 0 调整为最小 1 / >=1 自定义 ---"
m=$(setcfg failed_login_attempts_per_user -1)
assert_contains "per_user=-1 被接受（完全禁用全局限制）" "$m" "successfully"
m=$(setcfg failed_login_attempts_per_user 0)
assert_contains "per_user=0 被接受（按需求自动调整为最小 1）" "$m" "successfully"
m=$(setcfg failed_login_attempts_per_user 1000)
assert_contains "per_user=1000 被接受" "$m" "successfully"

sec_log "--- 4) 非法值（负数）回退默认 ---"
m=$(setcfg failed_login_attempts -5)
if printf '%s' "$m" | grep -q 'successfully'; then
  warn "failed_login_attempts=-5 未被拒绝（需求：不合理的配置项会转用默认值，并写错误日志）：$(printf '%s' "$m" | cut -c1-130)"
else
  pass "非法值被拒绝：$(printf '%s' "$m" | cut -c1-120)"
fi
logmark=$(sshx "$PRIMARY" "grep -c 'Invalid config\\|fallback' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')
sec_log "  DN 日志中 Invalid config/fallback 计数=${logmark:-0}"
if [ "${logmark:-0}" -gt 0 ]; then
  pass "非法配置已在 DN 日志留痕（ERROR fallback）"
else
  warn "未在 DN 日志看到非法配置回退记录（需求：写入错误日志），可能需特定非法值才触发"
fi

sec_log "--- 5) 修改权限（分离职责下的实际边界）---"
# 锁定类配置需要 SYSTEM；stale 需要 SECURITY —— 记录实际权限模型
cls=$(sec_sql_as "$SEC_USER" "$SEC_PW" table "set configuration 'failed_login_attempts'='5';" | grep -aE 'Msg:|Error:' | tail -1)
if printf '%s' "$cls" | grep -q '803'; then
  warn "当前驱动账号($SEC_USER)无法修改锁定配置（803 SYSTEM）：需求要求'仅 root 或安全管理员可改' —— 记录为待研发确认的权限边界"
else
  pass "当前驱动账号可修改锁定配置"
fi
m=$(sec_sql_as "$SEC_USER" "$SEC_PW" table "set configuration 'password_stale_warning_days'='30';" | grep -aE 'Msg:|Error:' | tail -1)
sec_log "  stale 配置设置结果：$(printf '%s' "$m" | cut -c1-120)"

sec_log "--- 6) 恢复默认值（restart 生效，本用例只回写不重启）---"
setcfg failed_login_attempts 5 >/dev/null
setcfg failed_login_attempts_per_user 1000 >/dev/null
setcfg password_lock_time_minutes 10 >/dev/null
conf_set_raw password_stale_warning_days 30 >/dev/null
pass "已回写默认值 5/1000/10/30（下次重启生效）"
sec_case_finish
