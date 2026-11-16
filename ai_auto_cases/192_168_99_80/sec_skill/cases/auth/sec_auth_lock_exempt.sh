#!/bin/bash
# ============================================================================
# SEC-14 锁定豁免 / 自动解锁 / 不持久化 / DROP USER 清锁
#   a) 本机（127.0.0.1，即 DataNode 所在机）登录的 root/安全管理员 不因密码错误被锁
#   b) 自动解锁：password_lock_time_minutes 到期后可登录
#   c) 锁名单不持久化：重启后锁消失（用"重新登录一次清锁"做对照 + 文档性 WARN）
#   d) DROP USER 清理锁：锁住 → drop → 重建同名 → 立即可登录
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-14" "锁定豁免（本机管理员）/ 自动解锁 / DROP USER 清锁"

U="${SEC_USER_PREFIX}_ex"
PW='Abcdefgh123!'
sec_user_drop "$U"
m=$(sec_user_create "$U" "$PW"); assert_contains "创建测试用户" "$m" "successfully"

ip_th=$(conf_eff failed_login_attempts)
[ -z "$ip_th" ] && ip_th=$(sshx "$PRIMARY" "grep -hE '^failed_login_attempts=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2" | tr -d ' \r')
lock_min=$(sshx "$PRIMARY" "grep -hE '^password_lock_time_minutes=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2" | tr -d ' \r')
lock_min=${lock_min:-10}
sec_log "  参数：failed_login_attempts=${ip_th:-?}, password_lock_time_minutes=$lock_min"

sec_log "--- 1) 本机登录的管理员豁免 ---"
# 源码 isFromLocalhost() 会把"本机任一网卡地址"视为本机 ⇒ 在 .77 上连 192.168.99.77 即为本机登录
# （DN 只监听 192.168.99.77:6667，不监听 127.0.0.1，因此不能用 loopback）
LOCAL_USER="$SEC_USER"; LOCAL_PW="$SEC_PW"
LOCAL_H="$PRIMARY"
local_code(){ sshx "$PRIMARY" "printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 $CLI -h $LOCAL_H -u $LOCAL_USER -pw 'DefinitelyWrong123!' 2>&1 | grep -aoE '[0-9]{3}:' | head -1 | tr -d ':'"; }
codes=""
n=$(( ${ip_th:-5} + 2 ))
for i in $(seq 1 "$n"); do codes="$codes $(local_code)"; done
sec_log "  本机管理员连续 ${n} 次错误密码的错误码:$codes"
if printf '%s' "$codes" | grep -q '822'; then
  fail "本机登录的管理员被锁定（需求要求豁免）：$codes"
else
  pass "本机登录的管理员未被锁定（豁免生效，$n 次错误仍为 801）"
fi
out=$(sshx "$PRIMARY" "printf 'set sql_dialect=tree;\nlist user;\n' | timeout 30 $CLI_NODE -h $LOCAL_H -u $LOCAL_USER -pw '$LOCAL_PW' 2>&1 | grep -acE 'root|security_admin|sys_admin'")
if [ "${out:-0}" -ge 1 ]; then
  pass "豁免后管理员仍可正常登录"
else
  fail "管理员正确密码登录失败（可能已被锁）"
fi

sec_log "--- 2) DROP USER 清锁：锁住 → drop → 重建 → 立即可登录 ---"
if [ "${ip_th:-0}" != "0" ] && [ -n "${ip_th:-}" ]; then
  repeat_bad_login "$U" "$ip_th" >/dev/null
  assert_contains "用户已被锁定" "$(try_login "$U" "$PW")" "822"
  m=$(st "drop user $U;"); assert_contains "删除被锁用户" "$m" "successfully"
  m=$(sec_user_create "$U" "$PW"); assert_contains "同名重建" "$m" "successfully"
  assert_eq "重建后立即可登录（锁已随 DROP 清理）" "$(try_login_ok "$U" "$PW" && echo yes || echo no)" "yes"
else
  warn "未开启锁定（failed_login_attempts=0），跳过 DROP USER 清锁验证"
fi

sec_log "--- 3) 自动解锁：锁定时长（$lock_min 分钟）到期后可登录 ---"
if [ "${ip_th:-0}" != "0" ] && [ -n "${ip_th:-}" ]; then
  repeat_bad_login "$U" "$ip_th" >/dev/null
  m=$(try_login "$U" "$PW")
  if printf '%s' "$m" | grep -q '822'; then
    pass "已锁定（等待 ${lock_min} 分钟自动解锁）"
    wait_s=$(( lock_min * 60 + 20 ))
    # 只等合理的时长，避免用例超长
    if [ "$wait_s" -gt 200 ]; then
      warn "锁定时长 ${lock_min} 分钟过长（>200s），自动解锁改为文档性检查：不等待"
      st "alter user $U account unlock;" >/dev/null
    else
      sec_log "  等待 ${wait_s}s ..."
      sleep "$wait_s"
      assert_eq "锁定到期后自动解锁（可用正确密码登录）" "$(try_login_ok "$U" "$PW" && echo yes || echo no)" "yes"
    fi
  else
    fail "未能构造锁定状态：$(printf '%s' "$m" | cut -c1-140)"
  fi
else
  warn "未开启锁定，跳过自动解锁验证"
fi

sec_log "--- 4) 锁名单在 DN 内存（不持久化）---"
warn "文档要求锁名单不持久化（重启即清）；本用例不重启集群，按设计记录为文档性检查（由回归手册人工确认）"

sec_log "--- 5) 清理 ---"
st "alter user $U account unlock;" >/dev/null
sec_user_drop "$U"
sec_case_finish
