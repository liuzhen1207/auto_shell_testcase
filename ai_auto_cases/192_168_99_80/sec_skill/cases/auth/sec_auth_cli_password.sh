#!/bin/bash
# ============================================================================
# SEC-11 客户端隐式密码输入（需求：start-cli 交互式输入并隐去明文）
#   a) `-pw` 不带值 → 打印 "please input your password:" 并从标准输入读取
#   b) 仍然保留 `-pw <password>` 用法
#   c) 交互式输入密码错误 → 801（与直接传密码一致）
#   d) 伪终端下输入不回显（密码明文不出现在终端输出）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-11" "客户端隐式密码输入（-pw 交互式 / 保留 -pw 值 / 不回显）"

U="${SEC_USER_PREFIX}_cli"
PW='Abcdefgh123!'
sec_user_drop "$U"
m=$(sec_user_create "$U" "$PW"); assert_contains "创建测试用户" "$m" "successfully"

sec_log "--- 1) 保留 -pw <password> 用法 ---"
out=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 60 "$CLI" -h "$PRIMARY" -u "$U" -pw "$PW" 2>&1)
assert_contains "-pw 直传密码可登录" "$out" "Successfully login"
assert_not_contains "-pw 直传时不出现交互提示" "$out" "please input your password"

sec_log "--- 2) -pw 不带值 → 交互式读取（管道喂入）---"
out=$(printf '%s\nset sql_dialect=tree;\nlist user;\n' "$PW" | timeout 60 "$CLI" -h "$PRIMARY" -u "$U" -pw 2>&1)
assert_contains "出现交互式提示 please input your password:" "$out" "please input your password"
assert_contains "交互式输入密码后可登录" "$out" "Successfully login"

sec_log "--- 3) 交互式输入错误密码 → 801 ---"
out=$(printf 'WrongPassw0rd!\n' | timeout 60 "$CLI" -h "$PRIMARY" -u "$U" -pw 2>&1)
assert_contains "交互式错误密码登录失败（801）" "$out" "801"
assert_not_contains "错误密码不应提示登录成功" "$out" "Successfully login"

sec_log "--- 4) 伪终端下不回显（script -qec）---"
if command -v script >/dev/null 2>&1; then
  # 用 expect 风格：先喂密码再喂退出；script 提供 pty，-q 静默 -e 返回子进程退出码 -c 命令
  out=$(printf '%s\n' "$PW" | timeout 60 script -qec "$CLI -h $PRIMARY -u $U -pw" /dev/null 2>&1)
  assert_contains "PTY 下出现交互提示" "$out" "please input your password"
  # script(1) 的 pty 自身会回显喂进去的输入（对照：script -qec 'cat' 会把输入打印两次），
  # 因此"是否回显"不能在脚本里可靠判定 —— 只记录，需真实终端人工确认
  if printf '%s' "$out" | grep -qF "$PW"; then
    warn "PTY 输出中出现密码明文，但 script(1) 的 pty 会回显喂入输入（对照已确认），无法据此判定是否回显；需真实终端人工确认"
  else
    pass "PTY 输出中未出现密码明文"
  fi
  assert_contains "PTY 下可登录" "$out" "Successfully login"
else
  warn "环境无 script，跳过 PTY 回显检查"
fi

sec_log "--- 5) 清理 ---"
sec_user_drop "$U"
sec_case_finish
