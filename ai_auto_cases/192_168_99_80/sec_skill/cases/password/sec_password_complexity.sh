#!/bin/bash
# ============================================================================
# SEC-02 密码复杂度（需求 b/c/d）
#   b) 大写+小写组合、c) 至少一个数字、d) 至少一个特殊字符
#   另覆盖：空格、非法字符（中文/分号/引号）、错误码 820 与文案逐条点名缺哪类
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
sec_parse_args "$@"
sec_case_init "SEC-02" "密码复杂度四要素 b/c/d + 非法字符/空格"

U="${SEC_USER_PREFIX}_cplx"
sec_conf_set enforce_strong_password true >/dev/null
assert_eq "enforce_strong_password 生效值" "$(sec_conf_get enforce_strong_password)" "true"
sec_user_drop "$U"

sec_log "--- 1) 缺大写 ---"
m=$(sec_user_create "$U" 'abcdefgh123!')
assert_contains "缺大写被拒" "$m" "820"
assert_contains "文案点名缺大写" "$m" "uppercase"

sec_log "--- 2) 缺小写 ---"
m=$(sec_user_create "$U" 'ABCDEFGH123!')
assert_contains "缺小写被拒" "$m" "820"
assert_contains "文案点名缺小写" "$m" "lowercase"

sec_log "--- 3) 缺数字 ---"
m=$(sec_user_create "$U" 'Abcdefghijk!')
assert_contains "缺数字被拒" "$m" "820"
assert_contains "文案点名缺数字" "$m" "digit"

sec_log "--- 4) 缺特殊字符 ---"
m=$(sec_user_create "$U" 'Abcdefgh1234')
assert_contains "缺特殊字符被拒" "$m" "820"
assert_contains "文案点名缺特殊字符" "$m" "special character"

sec_log "--- 5) 同时缺多项：文案应逐项列出 ---"
m=$(sec_user_create "$U" 'abcdefgh1234')     # 缺大写 + 缺特殊
assert_contains "缺大写+特殊被拒" "$m" "820"
assert_contains "同时点名 uppercase" "$m" "uppercase"
assert_contains "同时点名 special character" "$m" "special character"

sec_log "--- 6) 四要素齐备 → 成功 ---"
m=$(sec_user_create "$U" 'Abcdefgh123!')
assert_contains "四要素齐备创建成功" "$m" "successfully"
assert_eq "该用户可登录" "$(sec_login_ok "$U" 'Abcdefgh123!' && echo yes || echo no)" "yes"

sec_log "--- 7) 含空格（长度与四要素都够）---"
m=$(sec_user_create "${U}2" 'Abcdefgh 123!')
assert_contains "含空格被拒" "$m" "820"
assert_contains "空格文案" "$m" "cannot contain spaces"

sec_log "--- 8) 非法字符：中文 ---"
m=$(sec_user_create "${U}2" 'Abcdefgh123中')
assert_contains "中文被拒" "$m" "820"
assert_contains "非法字符文案" "$m" "can only contain letters, numbers"

sec_log "--- 9) 特殊字符集边界：! @ # \$ % ^ & * ( ) + = - _ 均应被接受 ---"
SPECIALS=('!' '@' '#' '$' '%' '^' '&' '*' '(' ')' '+' '=' '-' '_')
ok=0; bad=""
for c in "${SPECIALS[@]}"; do
  m=$(sec_user_create "${U}2" "Abcdefgh123${c}")
  printf '%s' "$m" | grep -q 'successfully' && ok=$((ok+1)) || bad="$bad [$c]"
  sec_user_drop "${U}2"
done
assert_eq "${#SPECIALS[@]} 个特殊字符都能作为特殊字符位" "$ok" "${#SPECIALS[@]}"
[ -n "$bad" ] && fail "以下特殊字符被拒：$bad" || pass "无特殊字符被误拒"

sec_log "--- 10) 不在允许集内的字符（如 / 与 :）应被拒 ---"
for c in '/' ':' '"' ';'; do
  m=$(sec_user_create "${U}2" "Abcdefgh123${c}")
  if printf '%s' "$m" | grep -qE '820|700'; then pass "字符 [$c] 被拒（820 白名单校验 或 700 语法拒绝）"; else fail "字符 [$c] 未被拒（实际=${m:0:120}）"; fi
  sec_user_drop "${U}2"
done

sec_user_drop "$U"; sec_user_drop "${U}2"
sec_case_finish
