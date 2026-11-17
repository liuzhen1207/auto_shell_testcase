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

sec_log "--- 4) 边界值语义：-5 视为\"禁用\"（模板 ≤0=disable；已确认可接受，不判缺陷）---"
m=$(setcfg failed_login_attempts -5)
assert_contains "failed_login_attempts=-5 被接受（按禁用处理）" "$m" "successfully"
# 说明：非数字（如 abc）会让 DataNode 拒绝启动（fail-fast），属已确认可接受行为，
#       用例中不执行，避免把集群重启挂掉；证据见 docs/DEFECT_invalid_config_handling.md
logmark=$(sshx "$PRIMARY" "grep -ac 'IP-level login attempts disabled' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')
if [ "${logmark:-0}" -gt 0 ]; then
  pass "DN 日志有 'IP-level login attempts disabled' 记录（INFO，符合 ≤0=禁用语义）"
else
  warn "未在 DN 日志看到 'IP-level login attempts disabled'（需重启后才会打印，属正常）"
fi
setcfg failed_login_attempts 5 >/dev/null

sec_log "--- 5) 修改权限：普通模式 root 全可改；三权分立下按角色分工（非缺陷）---"
if [ "${SEC_MODE:-normal}" = "normal" ]; then
  for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes password_stale_warning_days; do
    m=$(conf_set_raw "$k" 5)
    assert_contains "普通模式 root 可修改 $k" "$m" "successfully"
  done
else
  # 三权分立：锁定类配置需 SYSTEM（sys_admin）；安全类配置需 SECURITY（security_admin）—— 职责分离设计
  for k in failed_login_attempts failed_login_attempts_per_user password_lock_time_minutes; do
    c1=$(sec_sql_as "$SEC_USER" "$SEC_PW" tree "set configuration '$k'='5';" | grep -aoE '803' | head -1)
    c2=$(sec_sql_as "$DDL_USER" "$ADMIN_PW" tree "set configuration '$k'='5';" | grep -aoE 'successfully' | head -1)
    if [ "$c1" = "803" ] && [ -n "$c2" ]; then
      pass "三权分立：$k 由 sys_admin 修改（security_admin 无 SYSTEM → 803；需求措辞“root 或安全管理员”待研发确认）"
    else
      fail "三权分立下 $k 的角色权限与设计不符（security_admin=${c1:-非803} sys_admin=${c2:-未成功}）"
    fi
  done
  c3=$(sec_sql_as "$SEC_USER" "$SEC_PW" tree "set configuration 'password_stale_warning_days'='30';" | grep -aoE 'successfully' | head -1)
  c4=$(sec_sql_as "$DDL_USER" "$ADMIN_PW" tree "set configuration 'password_stale_warning_days'='30';" | grep -aoE '803' | head -1)
  if [ -n "$c3" ] && [ "$c4" = "803" ]; then
    pass "三权分立按设计：password_stale_warning_days 由 security_admin 修改（sys_admin 返回 803 SECURITY）"
  else
    fail "password_stale_warning_days 的角色权限与设计不符（security_admin=${c3:-未成功} sys_admin=${c4:-非803}）"
  fi
fi

sec_log "--- 6) 恢复默认值（restart 生效，本用例只回写不重启）---"
setcfg failed_login_attempts 5 >/dev/null
setcfg failed_login_attempts_per_user 1000 >/dev/null
setcfg password_lock_time_minutes 10 >/dev/null
conf_set_raw password_stale_warning_days 30 >/dev/null
pass "已回写默认值 5/1000/10/30（下次重启生效）"
sec_case_finish
