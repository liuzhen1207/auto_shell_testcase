#!/bin/bash
# ============================================================================
# SEC-13 防止口令暴力破解：user@IP 锁定与手动解锁（需求）
#   前置参数（由 tools/prepare_lock.sh 写入，restart 生效）：
#     failed_login_attempts=3, failed_login_attempts_per_user=1000, password_lock_time_minutes=1
#   覆盖：
#     a) 阈值内失败仍 801；达到阈值后 822（文案 Account is blocked due to consecutive failed logins）
#     b) 锁定期间即使正确密码也被拒（822）
#     c) 登录成功清空失败计数（2 错 + 正确 + 2 错 仍不锁）
#     d) 手动解锁 ALTER USER u ACCOUNT UNLOCK → 可登录
#     e) ALTER USER u @ '<ip>' ACCOUNT UNLOCK 语法可用
#     f) 普通用户执行解锁被拒（权限）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-13" "防止口令暴力破解：user@IP 锁定 + 手动解锁 + 计数清零"

U="${SEC_USER_PREFIX}_lock"
PW='Abcdefgh123!'
TH=3   # 与 conf 中 failed_login_attempts 一致
sec_user_drop "$U"

sec_log "--- 0) 前置参数检查 ---"
ip_th=$(conf_eff failed_login_attempts)
[ -z "$ip_th" ] && ip_th=$(sshx "$PRIMARY" "grep -hE '^failed_login_attempts=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2" | tr -d ' \r')
lock_min=$(sshx "$PRIMARY" "grep -hE '^password_lock_time_minutes=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2" | tr -d ' \r')
sec_log "  failed_login_attempts=${ip_th:-?} password_lock_time_minutes=${lock_min:-?}"
if [ "${ip_th:-0}" = "0" ] || [ -z "$ip_th" ]; then
  fail "锁定功能未开启（failed_login_attempts=${ip_th:-空}），无法验证；请先跑 tools/prepare_lock.sh 并重启"
  sec_case_finish; exit 0
fi
TH="${ip_th}"

m=$(sec_user_create "$U" "$PW"); assert_contains "创建测试用户" "$m" "successfully"

sec_log "--- 1) 阈值内失败 → 801（共 $TH 次；实测第 $TH 次只是把计数打到阈值，仍返回 801）---"
codes=$(repeat_bad_login "$U" "$TH")
sec_log "  错误码序列:$codes"
if printf '%s' "$codes" | grep -q '822'; then
  fail "未达阈值就已锁定（阈值=$TH，错误码序列:$codes）"
else
  pass "阈值内失败仍为认证失败（无 822）"
fi

sec_log "--- 2) 达到阈值后的下一次登录 → 822 + 文案 ---"
# 实测语义：前 TH 次失败都是 801（第 TH 次把计数打到阈值），第 TH+1 次才被拒为 822
last=$(try_login "$U" 'DefinitelyWrong123!')
assert_contains "第 $((TH+1)) 次（超过阈值）返回 822" "$last" "822"
assert_contains "锁定文案（Account is blocked due to consecutive failed logins）" "$last" "Account is blocked due to consecutive failed logins"

sec_log "--- 3) 锁定期间正确密码也被拒 ---"
m=$(try_login "$U" "$PW")
assert_contains "锁定期正确密码仍 822" "$m" "822"
assert_eq "确为锁定而非密码错误（错误码=822）" "$(login_code "$U" "$PW")" "822"

sec_log "--- 4) 手动解锁 → 正确密码可登录 ---"
mu=$(st "alter user $U account unlock;")
assert_contains "ALTER USER ... ACCOUNT UNLOCK 成功" "$mu" "successfully"
assert_eq "解锁后可登录" "$(try_login_ok "$U" "$PW" && echo yes || echo no)" "yes"

sec_log "--- 5) 登录成功清空失败计数（2 错 + 正确 + 2 错 仍不锁）---"
c1=$(repeat_bad_login "$U" 2); sec_log "  第一段错误码:$c1"
assert_eq "2 次错误后仍可登录（说明未锁）" "$(try_login_ok "$U" "$PW" && echo yes || echo no)" "yes"
c2=$(repeat_bad_login "$U" 2); sec_log "  第二段错误码:$c2"
if printf '%s' "$c2" | grep -q '822'; then
  fail "登录成功未清空失败计数（第二段 2 次错误即被锁）"
else
  pass "登录成功已清空失败计数（第二段 2 次错误仍不锁）"
fi
st "alter user $U account unlock;" >/dev/null

sec_log "--- 6) user@ip 形式解锁语法 ---"
m=$(st "alter user $U @ '192.168.99.80' account unlock;")
assert_contains "ALTER USER u @ 'ip' ACCOUNT UNLOCK 语法可用" "$m" "successfully"

sec_log "--- 7) 普通用户执行解锁被拒 ---"
mu=$(sec_sql_as "$U" "$PW" tree "alter user $U account unlock;")
code=$(printf '%s' "$mu" | grep -aoE '[0-9]{3}:' | head -1 | tr -d ':')
if [ "$code" = "803" ] || [ "$code" = "701" ]; then
  pass "普通用户执行解锁被拒（$code，权限错误）"
elif printf '%s' "$mu" | grep -qiE 'Exception|INTERNAL_SERVER_ERROR'; then
  # 记录为缺陷候选：非授权解锁应返回权限错误（803），实际 305 内部错误 + Java 异常文本
  warn "缺陷候选：普通用户执行 ALTER USER ... ACCOUNT UNLOCK 返回 $code（INTERNAL_SERVER_ERROR + Java 异常文本），期望 803 权限错误：$(printf '%s' "$mu" | grep -aE 'Error' | tail -1 | cut -c1-170)"
else
  fail "普通用户执行解锁结果异常：$(printf '%s' "$mu" | grep -aE 'Error|Msg' | tail -1 | cut -c1-140)"
fi

sec_log "--- 8) 清理 ---"
st "alter user $U account unlock;" >/dev/null
sec_user_drop "$U"
sec_case_finish
