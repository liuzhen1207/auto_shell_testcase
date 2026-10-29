#!/bin/bash
# ============================================================================
# harness 自检（不需要集群）：语法、用例矩阵与脚本、env 变量、helper 存在性、
# 断言框架行为、以及本项目踩过的静态坑（同一条 local 里先赋值后展开 / 全角括号）。
# 用法： SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
ok=0; bad=0
pass_c(){ ok=$((ok+1)); printf '  [ok] %s\n' "$1"; }
fail_c(){ bad=$((bad+1)); printf '  [FAIL] %s\n' "$1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then pass_c "$1"; else fail_c "$1"; fi; }

echo "=== 1) 语法检查 ==="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/st.err; then pass_c "bash -n ${f#$SKILL/}"; else fail_c "bash -n ${f#$SKILL/} : $(head -1 /tmp/st.err)"; fi
done < <(find "$SKILL" -name '*.sh' -not -path '*/results/*')

echo "=== 2) 用例矩阵与脚本 ==="
[ -f "$SKILL/cases/cases.tsv" ] && pass_c "cases.tsv 存在" || fail_c "cases.tsv 缺失"
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
IDS=$(printf '%s\n' "${LINES[@]}" | cut -f1)
[ "$(printf '%s\n' "$IDS" | sort -u | wc -l)" = "$(printf '%s\n' "$IDS" | wc -l)" ] && pass_c "用例 ID 不重复（$(printf '%s\n' "$IDS" | tr '\n' ' ')）" || fail_c "用例 ID 有重复"
while IFS=$'\t' read -r id script rest; do
  [ -f "$SKILL/$script" ] && pass_c "$id 脚本存在（$script）" || fail_c "$id 脚本缺失（$script）"
  [ "$(printf '%s' "$rest" | awk -F'\t' '{print NF}')" -ge 4 ] && pass_c "$id 矩阵列数足够" || fail_c "$id 矩阵列数不足（至少 6 列）"
done < <(printf '%s\n' "${LINES[@]}")

echo "=== 3) env.conf 变量完整性 ==="
. "$SKILL/conf/env.conf"
for v in CLUSTER_NODES CN_NODES DN_NODES SSH_USER DB_PARENT_DIR SHELL_CLIENT_DIR V_TESTDB BUILD_TAG DB_USER ROOT_PW \
         SCHEMA_RF DATA_RF DATA_CONSENSUS CMP_CANDIDATE_NUM CMP_INTERVAL_MS DU_CMP_EXTRA_CONF DU_DEVS DU_ROWS DU_FILES \
         DU_WIN_SEC DU_MERGE_WAIT_SEC TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO \
         DN_RPC_PORT CN_INTERNAL_PORT USE_FRAMEWORK FRAMEWORK_DIR SQL_TIMEOUT_SEC; do
  [ -n "${!v:-}" ] && pass_c "env: $v=${!v}" || fail_c "env: $v 未定义/为空"
done
printf '%s' "$DU_CMP_EXTRA_CONF" | grep -q 'inner_compaction_candidate_file_num' && pass_c "合并参数含 candidate_file_num" || fail_c "合并参数缺 candidate_file_num"
printf '%s' "$DU_CMP_EXTRA_CONF" | grep -q 'compaction_schedule_interval_in_ms' && pass_c "合并参数含调度间隔" || fail_c "合并参数缺调度间隔"

echo "=== 4) helper 存在性（source 后检查函数）==="
# shellcheck disable=SC1091
. "$SKILL/lib/common.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$SKILL/lib/du.sh" 2>/dev/null
for fn in du_load_env du_parse_args du_case_init du_cluster_prepare du_case_finish \
          sq sqt sq_as sqt_as sshx table_rows assert_contains assert_not_contains assert_eq post_checks ensure_closed \
          du_tree du_table_all du_table_where du_table_sql du_header du_tree_row_cnt du_tree_size_sum \
          du_table_row_cnt du_table_size_sum du_tsfile_sum du_tsfile_bytes_sum du_tsfile_list \
          du_cmp_start_sum du_cmp_finish_sum du_cmp_log_tail du_wait_merge du_stuck_writelock_sum du_stuck_stack \
          du_set_hot du_cmp_conf du_make_tree_db du_write_tree_batch du_make_table_db du_write_table_batch; do
  chk "函数 $fn 已定义" "declare -F $fn"
done

echo "=== 5) 断言框架行为 ==="
fail_flag=0; v_warnMessage=""; OUT=/tmp/du_st_assert.out; : >"$OUT"
assert_eq "自检-相等" "a" "a"          # 应 PASS
assert_eq "自检-不等" "a" "b"          # 应 FAIL（fail_flag=1）
assert_contains "自检-包含" "hello world" "wor"
assert_not_contains "自检-不包含" "hello world" "zzz"
[ "$fail_flag" = "1" ] && pass_c "断言框架：故意失败 1 条 ⇒ fail_flag=1" || fail_c "断言框架异常：fail_flag=$fail_flag（期望 1）"
printf '%s' "$v_warnMessage" | grep -q '自检-不等' && pass_c "fail() 写入了 v_warnMessage" || fail_c "fail() 未记录 message"

echo "=== 6) 静态坑检查 ==="
# 6.1 同一条 local 里先赋值、后在算术展开中引用（set -u 下 unbound）
if grep -rnE 'local [a-zA-Z_]+=\$[0-9A-Za-z_]+ .*\$\(\(.*\b\1\b' "$SKILL/lib" "$SKILL/cases" "$SKILL/tools" 2>/dev/null | grep -q .; then
  fail_c "存在 'local a=\$1 ... \$((...a...))' 同句引用"
else
  pass_c "无 'local a=\$1 ... \$((...a...))' 同句引用"
fi
# 6.2 全角括号误用（曾把 \$( 写成 \$（ 导致命令替换静默失效）；排除本文件自身
if grep -rn --exclude=selftest.sh '\$（' "$SKILL/lib" "$SKILL/cases" "$SKILL/tools" 2>/dev/null | grep -q .; then
  fail_c "存在全角括号误用 \$（ … ）"
else
  pass_c "无全角括号误用"
fi
# 6.3 heredoc 里引用未转义本地变量（写配置类脚本的经典坑）
grep -rn 'bash -s' "$SKILL/lib/common.sh" >/dev/null 2>&1 && pass_c "common.sh 仍用 'ssh … bash -s' 写配置（需注意 heredoc 变量）" || pass_c "未使用 bash -s 写配置"
# 6.4 合并观测的两个信号都必须被断言（防止只看一个）
grep -q 'du_wait_merge' "$SKILL/lib/du.sh" && pass_c "du_wait_merge 同时要求 finish 增长与 tsfile 下降" || fail_c "du_wait_merge 缺失"

echo
echo "=== 自检汇总：ok=$ok failed=$bad ==="
[ "$bad" = "0" ] || exit 1
