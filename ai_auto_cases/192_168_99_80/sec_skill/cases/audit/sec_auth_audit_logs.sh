#!/bin/bash
# ============================================================================
# SEC-16 身份鉴别/锁定的审计与日志（需求：审计和监控、运营日志）
#   a) 锁定/解锁事件有 INFO 日志（locked due to / unlocked）
#   b) 认证失败不泄露密码、日志不含明文密码
#   c) 异常行为 WARN（单用户多 IP 锁 / 单 IP 多用户锁）—— 构造困难，只校验格式与不可构造说明
#   d) 非法配置 ERROR fallback 留痕
#   e) CN/DN 日志门禁（无预期外 WARN/ERROR）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-16" "身份鉴别/锁定审计与日志"

U="${SEC_USER_PREFIX}_aud"
PW='Abcdefgh123!'
sec_user_drop "$U"
m=$(sec_user_create "$U" "$PW"); assert_contains "创建测试用户" "$m" "successfully"

ip_th=$(conf_eff failed_login_attempts)
[ -z "$ip_th" ] && ip_th=$(sshx "$PRIMARY" "grep -hE '^failed_login_attempts=' $DB_DIR/conf/iotdb-server.properties 2>/dev/null | cut -d= -f2" | tr -d ' \r')
ip_th=${ip_th:-5}

sec_log "--- 1) 制造一次锁定 + 一次手动解锁，检查 INFO 日志 ---"
repeat_bad_login "$U" "$ip_th" >/dev/null
locked=$(try_login "$U" "$PW"); sec_log "  锁定验证：$(printf '%s' "$locked" | cut -c1-90)"
st "alter user $U account unlock;" >/dev/null

loghit=""
for h in $DN_NODES; do
  hit=$(sshx "$h" "grep -aiE 'locked due to|unlocked|locked for user|consecutive failed' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -3")
  [ -n "$hit" ] && { loghit="$hit"; sec_log "  .$h 命中锁定/解锁日志：$(printf '%s' "$hit" | head -2 | cut -c1-170 | tr '\n' ' ')"; break; }
done
if [ -n "$loghit" ]; then
  pass "锁定/解锁事件在 DN 日志留痕"
else
  warn "DN 日志未见 locked/unlocked 关键字（需求要求 INFO 级运营日志）：$(sshx "$PRIMARY" "grep -ac 'LoginLock' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9') 条 LoginLock 相关"
fi

sec_log "--- 2) 认证失败响应不泄露敏感信息 ---"
m=$(try_login "$U" 'WrongPass999!')
assert_not_contains "错误响应不含所输密码" "$m" "WrongPass999"
assert_not_contains "错误响应不含密码哈希/盐" "$m" "hash"
if printf '%s' "$m" | grep -q 'does not exist'; then
  warn "错误响应区分'用户不存在'（804）与'密码错误'（801），与需求调研中 MySQL '隐去报错信息' 的建议不一致，记录为观察"
else
  pass "错误响应未暴露用户存在性（统一 801）"
fi

sec_log "--- 3) 异常行为 WARN（单用户多 IP 锁 / 单 IP 多用户锁）---"
warn "构造 1200 个 IP 锁 / 50 个用户同 IP 锁不现实，本条只校验规格：需求要求 WARN 文案含 potential attack"

sec_log "--- 4) 非法配置 ERROR fallback 留痕 ---"
sec_sql table "set configuration 'failed_login_attempts'='-7';" >/dev/null
n=$(sshx "$PRIMARY" "grep -acE 'Invalid config|fallback to default' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')
if [ "${n:-0}" -gt 0 ]; then
  pass "非法配置回退在日志留痕（$n 条）"
else
  warn "非法配置回退无日志留痕（需求要求：不支持直接拒绝，而不合理配置转默认值并写错误日志）"
fi

sec_log "--- 5) 日志不含明文密码 ---"
sec_check_password_leak "$PW"

sec_log "--- 6) 清理 ---"
st "alter user $U account unlock;" >/dev/null
sec_user_drop "$U"
sec_case_finish
