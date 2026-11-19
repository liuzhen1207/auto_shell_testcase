#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1497 / 【TIMECHODB-0764】
#   数据库客户端连接数达到上限（默认 1000）时，新连接的报错信息不合理：
#   旧文案 "Error: Can't execute sql because ... Check whether the server exists
#   or is alive, or whether the serv..."，无法区分“连接资源耗尽”。
#   期望：明确提示 "There are not enough connection resources available"。
#
#   RC3 已含修复：dd94f472 IoTDBConnection 增加 "Socket is closed by peer" 判定，
#   与 "Connection reset" 一样映射为连接资源不足的文案。
#
#   验证版本：2.0.13.1 RC3 / ac7f95e
#   两个独立用例，各自要求干净集群环境（由 tools/run_case_clean.sh 保证）：
#     RN-209 普通模式（root 登录）
#     RN-210 三权分立（sys_admin 探测；root 被禁 803）
# ============================================================================
RN0764_LIMIT=6
RN0764_PW='TimechoDB@2021'

# 设置上限并重启 DN（需 root 可用，即普通模式）
_rn0764_set_limit() {
  local out
  out=$(T "set configuration 'dn_rpc_max_concurrent_client_num'='${RN0764_LIMIT}'")
  assert_ok "$out" "设置 dn_rpc_max_concurrent_client_num=${RN0764_LIMIT}"
  bash "$BASE/tools/restart_dns.sh" > /tmp/rn0764_restart_dns.log 2>&1
  local running
  running=$(T "show cluster" 2>/dev/null | grep -c Running)
  [ "${running:-0}" -ge 8 ] && ok "重启 DN 后集群 8/8" || fail "重启 DN 后集群 ${running:-0}/8"
}

# 断言：JDBC 第 N+1 个连接的报错文案 + CLI 报错文案
_rn0764_assert() {
  local user="$1" pw="$2" tag="$3" out
  out=$(bash "$BASE/tools/cli_conn_probe.sh" probe "$user" "$pw" "$RN0764_LIMIT" 2>&1)
  echo "$out" | sed 's/^/    /'
  assert_contains "$out" "EXTRA_OK=false" "$tag 达到上限后新连接被拒绝"
  assert_contains "$out" "HAS_CLEAR_MSG=true" "$tag 报错文案可识别（not enough connection resources / Insufficient connection pool resources）"
  assert_contains "$out" "HAS_OLD_MSG=false" "$tag 报错不含旧文案 'Check whether the server exists or is alive'"
  assert_contains "$out" "EXISTING_OK=true" "$tag 达到上限时已有连接仍可执行查询"
  assert_contains "$out" "AFTER_RELEASE_OK=true" "$tag 释放一个连接后新连接可恢复"

  # CLI：占满连接后用 CLI 连接，必须被拒绝且文案可识别
  out=$(bash "$BASE/tools/cli_conn_probe.sh" cli "$user" "$pw" 40 2>&1)
  echo "$out" | sed 's/^/    /'
  assert_contains "$out" "CLI_REJECTED=true" "$tag CLI 新连接被拒绝"
  assert_contains "$out" "CLI_HAS_CLEAR_MSG=true" "$tag CLI 报错文案可识别"
  assert_contains "$out" "CLI_HAS_OLD_MSG=false" "$tag CLI 报错不含旧文案"
}

_rn0764_restore() {
  T "set configuration 'dn_rpc_max_concurrent_client_num'='1000'" >/dev/null 2>&1
}

case_RN209() {
  echo "  --- 普通模式：客户端连接数上限报错文案 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    fail "当前不是普通模式（root 被禁），无法执行 RN-209"
    return
  fi
  ok "当前为普通模式（root 可登录）"
  _rn0764_set_limit
  _rn0764_assert root "$RN0764_PW" "[普通]"
  _rn0764_restore
}

case_RN210() {
  echo "  --- 三权分立：客户端连接数上限报错文案 ---"
  if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
    ok "当前已是三权分立（root 被拒 803），跳过开启"
  else
    # 先在普通模式下设置上限并重启 DN（三权分立下 set configuration 需 SECURITY，root 被禁）
    _rn0764_set_limit
    echo "  开启三权分立…"
    ( cd "$BASE" && NEW="$NEW" bash tools/mode.sh on ) > /tmp/rn0764_mode_on.log 2>&1
    if T "show cluster" 2>&1 | grep -q "SUPER USER is not allowed"; then
      ok "三权分立已开启：root 被拒（803）"
    else
      fail "开启三权分立后 root 仍可登录"
      return
    fi
  fi
  if L sys_admin "$RN0764_PW" "show cluster" 2>&1 | grep -q Running; then
    ok "sys_admin 可登录"
  else
    fail "sys_admin 登录失败"
    return
  fi
  _rn0764_assert sys_admin "$RN0764_PW" "[三权分立]"
}

CASES+=(
"RN-209|TDB-1497 连接数上限报错（普通模式）|异常|连接达到上限时新连接报错含资源不足提示，不含旧文案；已有连接不受影响，释放后恢复|case_RN209"
"RN-210|TDB-1497 连接数上限报错（三权分立）|异常|三权分立下 sys_admin 触发上限，报错文案同上；root 被拒 803|case_RN210"
)
