#!/bin/bash
# ============================================================================
# 存储模块 CRUD 专项 skill —— harness 自检（不需要集群、不碰集群）
#   语法、用例矩阵一致性、env 变量、helper 存在性、断言框架行为（含"故意失败必须
#   fail_flag>0"的负向测试）、异常正则覆盖、以及本项目踩过的静态坑。
# 用法： SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
#   ⚠ 只做静态检查：不启停集群、不执行任何用例（正在跑长回归时也可以安全执行）。
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
  if bash -n "$f" 2>/tmp/cr_st.err; then pass_c "bash -n ${f#$SKILL/}"; else fail_c "bash -n ${f#$SKILL/} : $(head -1 /tmp/cr_st.err)"; fi
done < <(find "$SKILL" -name '*.sh' -not -path '*/results/*')

echo "=== 2) 用例矩阵与脚本（cases/cases.tsv ⇔ cases/*/*.sh 双向一致）==="
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
N_CASES=${#LINES[@]}                       # 以矩阵**数据行数**为准（空矩阵就是 0，不要被空数组展开成 1 行骗过）
IDS=""
[ "$N_CASES" -gt 0 ] && IDS=$(printf '%s\n' "${LINES[@]}" | cut -f1)
n_ids=$(printf '%s' "$IDS" | grep -c . || true)
[ "$n_ids" = "$N_CASES" ] && pass_c "用例 ID 齐全且不重复（$(printf '%s' "$IDS" | tr '\n' ' ')）" || fail_c "用例 ID 有重复/缺失（矩阵行数=$N_CASES，ID 数=$n_ids）"
[ "$N_CASES" -ge 1 ] && pass_c "用例数=$N_CASES（≥1）" || fail_c "用例数偏少（$N_CASES，期望 ≥1：至少一条冒烟）"
if [ "$N_CASES" -gt 0 ]; then
  while IFS=$'\t' read -r id script rest; do
    [ -f "$SKILL/$script" ] && pass_c "$id 脚本存在（$script）" || fail_c "$id 脚本缺失（$script）"
  done < <(printf '%s\n' "${LINES[@]}")
fi
# 反向：cases/ 下存在但矩阵未登记的脚本 ⇒ FAIL（否则"加了脚本却在集合里静默跳过"会漏测）
n_orphan=0
while IFS= read -r f; do
  rel=${f#$SKILL/}
  grep -qE "[[:space:]]${rel}([[:space:]]|\$)" "$SKILL/cases/cases.tsv" || { fail_c "脚本未登记到 cases.tsv：$rel"; n_orphan=$((n_orphan+1)); }
done < <(find "$SKILL/cases" -name '*.sh' | sort)
[ "$n_orphan" = 0 ] && pass_c "cases/ 下的脚本全部已在 cases.tsv 登记"

echo "=== 3) env.conf 变量完整性 ==="
. "$SKILL/conf/env.conf"
for v in CLUSTER_NODES CN_NODES DN_NODES SSH_USER DB_PARENT_DIR SHELL_CLIENT_DIR V_TESTDB BUILD_TAG DB_USER ROOT_PW \
         SCHEMA_RF DATA_RF DATA_CONSENSUS CMP_CANDIDATE_NUM CMP_INTERVAL_MS CMP_EXTRA_CONF CMP_EXTRA_CROSS \
         CO_DEVS CO_ROWS CO_BATCHES CO_WIN_SEC CO_MERGE_WAIT_SEC CO_PERF_DEVS CO_PERF_ROWS CO_PERF_BATCHES CO_PERF_WIN \
         TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO DN_METRIC_PORT USE_FRAMEWORK SQL_TIMEOUT_SEC; do
  [ -n "${!v:-}" ] && pass_c "env: $v=${!v}" || fail_c "env: $v 未定义/为空"
done
printf '%s' "$CMP_EXTRA_CONF" | grep -q 'enable_seq_space_compaction=true' && pass_c "默认组合开启 seq 合并" || fail_c "默认组合未开启 seq 合并"
printf '%s' "$CMP_EXTRA_CONF" | grep -q 'inner_compaction_candidate_file_num' && pass_c "默认组合含候选文件数" || fail_c "默认组合缺候选文件数"
printf '%s' "$CMP_EXTRA_CROSS" | grep -q 'enable_cross_space_compaction=true' && pass_c "跨空间组合开启 cross" || fail_c "跨空间组合未开启 cross"
# CRUD skill 的默认版本（换环境只改 env.conf，这里锁住"默认是 RC7"这一约定）
grep -qE '^V_TESTDB="\$\{V_TESTDB:-v20121rc7_' "$SKILL/conf/env.conf" && pass_c "env.conf 默认版本是 RC7（v20121rc7_*）" || fail_c "env.conf 默认版本不是 RC7"

echo "=== 4) helper 存在性 ==="
. "$SKILL/lib/common.sh" 2>/dev/null
. "$SKILL/lib/cmp.sh" 2>/dev/null
for fn in cmp_load_env cmp_parse_args cmp_case_init cmp_cluster_prepare cmp_case_finish \
          sq sqt sq_node sqt_node sql_lines_tree sql_lines_table sshx table_rows row_sum ensure_closed \
          check_sync_lag consistency_check check_logs consistency_check_on check_sync_lag_on post_checks \
          cmp_make_tree_db cmp_write_tree_batch cmp_make_table_db cmp_write_table_batch cmp_bulk_tree_session \
          cmp_seq_sum cmp_unseq_sum cmp_all_sum cmp_bytes_sum cmp_tsfile_list cmp_per_node \
          cmp_inner_finish cmp_cross_finish cmp_log_tail cmp_stuck_sum cmp_wait_merge cmp_fingerprint \
          cmp_fingerprint_on cmp_assert_nodes_same cmp_assert_same \
          cmp_start_cnt_all cmp_finish_cnt_all \
          cmp_eff cmp_eff_all cmp_tpl_has cmp_set_hot cmp_is_hot_key \
          cmp_node_ids cmp_node_id_of cmp_node_cnt cmp_remove_dn cmp_remove_cn cmp_wait_node_gone \
          cmp_check_logs_on cmp_perf_record; do
  chk "函数 $fn 已定义" "declare -F $fn"
done

echo "=== 5) 断言框架行为（含负向：故意失败必须 fail_flag>0）==="
fail_flag=0; v_warnMessage=""; OUT=/tmp/cr_st_assert.out; : >"$OUT"
assert_eq "自检-相等" "a" "a"
assert_eq "自检-不等" "a" "b"
assert_contains "自检-包含" "hello world" "wor"
assert_not_contains "自检-不包含" "hello world" "zzz"
[ "$fail_flag" = "1" ] && pass_c "断言框架：故意失败 1 条 ⇒ fail_flag=1" || fail_c "断言框架异常：fail_flag=$fail_flag"
printf '%s' "$v_warnMessage" | grep -q '自检-不等' && pass_c "fail() 写入了 v_warnMessage" || fail_c "fail() 未记录 message"

echo "=== 6) 异常正则覆盖（NPE/越界/OOM/overlap 等）==="
for pat in NullPointerException OutOfMemoryError IndexOutOfBoundsException ArrayIndexOutOfBoundsException overlapped; do
  printf '%s' "$COMMON_ERR_PAT" | grep -q "$pat" && pass_c "COMMON_ERR_PAT 含 $pat" || fail_c "COMMON_ERR_PAT 缺 $pat"
done
printf '%s' "$COMMON_ERR_PAT" | grep -q 'CompactionTableSchemaNotMatchException' && pass_c "含 CompactionTableSchemaNotMatchException" || fail_c "缺 CompactionTableSchemaNotMatchException"

echo "=== 6b) CRUD 专属日志判据：钩子默认空 + CRUD 层可用 + 集合清单 ==="
# 钩子必须是"纯增量"：默认空 ⇒ check_logs 行为与合并 skill 的版本一致（合并/TTL/元数据 skill 不受影响）
printf '%s' "${CMP_ERR_PAT_CUSTOM:-}" | grep -q . && fail_c "CMP_ERR_PAT_CUSTOM 默认非空（会改变默认行为）" || pass_c "CMP_ERR_PAT_CUSTOM 默认空"
printf '%s' "${CMP_POSITIVE_EVIDENCE_FN:-}" | grep -q . && fail_c "CMP_POSITIVE_EVIDENCE_FN 默认非空（会改变默认行为）" || pass_c "CMP_POSITIVE_EVIDENCE_FN 默认空"
grep -q '合并任务累计' "$SKILL/lib/common.sh" && pass_c "check_logs 仍保留合并正证据（钩子未设置时的回退路径）" || fail_c "check_logs 的合并正证据回退路径缺失"
chk "lib/crud_ext.sh 存在" "[ -f '$SKILL/lib/crud_ext.sh' ]"
. "$SKILL/lib/crud_ext.sh" 2>/dev/null
for fn in crud_err_pat_extra crud_install_err_pat crud_positive_evidence crud_log_sum crud_check_logs; do
  chk "函数 $fn 已定义（crud_ext.sh）" "declare -F $fn"
done
printf '%s' "${CMP_ERR_PAT_CUSTOM:-}" | grep -q . && fail_c "source crud_ext.sh 后 CMP_ERR_PAT_CUSTOM 被自动设置（必须用例显式 opt-in）" || pass_c "source crud_ext.sh 不会自动改默认行为"
# ④ 集合 = 显式 ID 清单（不能退回"编号区间"）：抽查两个语义归属 + 确认没有区间通配
grep -q 'set_ids="CR-13 CR-14"' "$SKILL/tools/run_all.sh" && pass_c "run_all.sh：load = CR-13,CR-14" || fail_c "run_all.sh：load 集合不是显式 CR-13 CR-14"
grep -q 'set_ids="CR-11 CR-12"' "$SKILL/tools/run_all.sh" && pass_c "run_all.sh：object = CR-11,CR-12" || fail_c "run_all.sh：object 集合不是显式 CR-11 CR-12"
grep -qE 'CR-[0-9]\[0-9\]' "$SKILL/tools/run_all.sh" && fail_c "run_all.sh 的 case_in_set 里仍有编号区间通配" || pass_c "run_all.sh 的 case_in_set 已无编号区间通配"

echo "=== 7) 静态坑检查 ==="
if grep -rnE 'local [a-zA-Z_]+=\$[0-9A-Za-z_]+ .*\$\(\(.*\b\1\b' "$SKILL/lib" "$SKILL/cases" 2>/dev/null | grep -q .; then
  fail_c "存在 'local a=\$1 ... \$((...a...))' 同句引用"; else pass_c "无同句 local 引用问题"; fi
if grep -rn --exclude=selftest.sh '\$（' "$SKILL/lib" "$SKILL/cases" "$SKILL/tools" 2>/dev/null | grep -q .; then
  fail_c "存在全角括号误用 \$（"; else pass_c "无全角括号误用"; fi
# CRUD 约定：用例 ID 一律 CR- 前缀；用例里的库名一律 root.cr*（不与其它 skill / 长回归互相干扰）
n_bad_id=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$id" in CR-*) ;; *) fail_c "用例 ID 未用 CR- 前缀：$id"; n_bad_id=$((n_bad_id+1)) ;; esac
done < <(printf '%s\n' "$IDS")
[ "$n_bad_id" = 0 ] && pass_c "用例 ID 前缀统一 CR-"
bad_db=$(grep -rhoE 'root\.[A-Za-z0-9_]+' "$SKILL"/cases/*/*.sh 2>/dev/null | grep -vE '^root\.cr' | sort -u | tr '\n' ' ')
[ -z "$bad_db" ] && pass_c "用例库名统一 root.cr*" || fail_c "用例里存在非 root.cr* 的库名：$bad_db"
n_missing=0; n_sh=0
for f in "$SKILL"/cases/*/*.sh; do
  [ -f "$f" ] || continue          # 无匹配时 glob 保留字面量，这里挡掉
  n_sh=$((n_sh+1))
  grep -q 'post_checks\|check_sync_lag_on' "$f" || { fail_c "$(basename "$f") 未调用统一收尾"; n_missing=$((n_missing+1)); }
  grep -q 'cmp_case_finish' "$f" || { fail_c "$(basename "$f") 未调用 cmp_case_finish"; n_missing=$((n_missing+1)); }
done
[ "$n_missing" = "0" ] && pass_c "用例统一收尾：已检查 $n_sh 个脚本，全部调用（矩阵 $N_CASES 条）" || fail_c "有脚本未调用统一收尾（检查 $n_sh 个）"

echo "=== 12) EXTRA_CONF 覆盖语义（同键后者胜；回归 2026-10-21 W-08 的 3 条假 FAIL）==="
# 用例常在 *_EXTRA_DEFAULT 后面追加"覆盖同一键"的值（W-08 就是这个办法把阈值调成 1MB）。
# 写入侧是 sed 删除 + 追加 ⇒ 文件里只剩最后一个值；若校验侧仍按原始列表逐条比对，
# 前面那条默认值必然对不上 ⇒ 每个节点各报 1 条假 FAIL（RC8 实测 W-08 fail_flag=3）。
_xo_out=$(EXTRA_CONF="a=1,b=2,a=3" cluster_extra_pairs 2>/dev/null)
[ "$_xo_out" = "$(printf 'a=3\nb=2')" ] \
  && pass_c "cluster_extra_pairs：同键后者胜且保序（a=1,b=2,a=3 → a=3,b=2）" \
  || fail_c "cluster_extra_pairs 去重不符合后者胜（得到：$(printf '%s' "$_xo_out" | tr '\n' ' ')）"
_xo_wal="wal_file_size_threshold_in_byte=31457280,wal_mode=ASYNC,wal_file_size_threshold_in_byte=1048576"
_xo_n=$(EXTRA_CONF="$_xo_wal" cluster_extra_pairs | grep -c '^wal_file_size_threshold_in_byte=')
_xo_v=$(EXTRA_CONF="$_xo_wal" cluster_extra_pairs | grep '^wal_file_size_threshold_in_byte=' | cut -d= -f2-)
[ "$_xo_n" = "1" ] && [ "$_xo_v" = "1048576" ] \
  && pass_c "cluster_extra_pairs：默认阈值被用例覆盖后只剩 1 条（=1048576）" \
  || fail_c "cluster_extra_pairs 覆盖失败（出现 $_xo_n 次，值=$_xo_v）"
_xo_empty=$(EXTRA_CONF="" cluster_extra_pairs 2>/dev/null)
[ -z "$_xo_empty" ] && pass_c "cluster_extra_pairs：空 EXTRA_CONF 返回空（set -u 下不报错）" \
  || fail_c "cluster_extra_pairs 空输入行为异常"

echo
echo "=== 自检汇总：ok=$ok failed=$bad ==="
[ "$bad" = "0" ] || exit 1
