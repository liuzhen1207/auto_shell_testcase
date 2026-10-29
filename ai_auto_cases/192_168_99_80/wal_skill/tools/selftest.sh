#!/bin/bash
# ============================================================================
# 存储模块 WAL（写前日志）专项 skill —— harness 自检（不需要集群、不碰集群）
#   语法、用例矩阵一致性（矩阵里有、脚本还没写 ⇒ 记 [planned]，**不算失败**）、
#   env 变量、helper 存在性、WAL 观测层（lib/wal_ext.sh）函数与"source 不改默认行为"、
#   12 个集合（run_all.sh case_in_set）的显式 ID 清单逐字核对、异常正则覆盖、
#   断言框架行为（含"故意失败必须 fail_flag>0"的负向测试），以及本项目踩过的静态坑
#   （WAL 专属：wal_mode=DISABLE 白名单、调用 wal_* 观测函数必须 source lib/wal_ext.sh）。
# 用法： SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh
#   ⚠ 只做静态检查：不启停集群、不执行任何用例（正在跑长回归时也可以安全执行）。
#   ⚠ 只 source lib/common.sh / lib/cmp.sh / lib/wal_ext.sh，**绝不调用**
#     cmp_cluster_prepare / cluster_stop / cluster_start / cluster_clean。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
ok=0; bad=0; planned=0
pass_c(){ ok=$((ok+1)); printf '  [ok] %s\n' "$1"; }
fail_c(){ bad=$((bad+1)); printf '  [FAIL] %s\n' "$1"; }
plan_c(){ planned=$((planned+1)); printf '  [planned] %s\n' "$1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then pass_c "$1"; else fail_c "$1"; fi; }

# ---------------------------------------------------------------------------
# WAL 观测层函数清单（唯一来源：lib/wal_ext.sh 的函数名单）——helper 存在性、
# "调用 wal_* 必须 source wal_ext.sh" 两处共用。
# ---------------------------------------------------------------------------
WAL_FNS="wal_dir_roots wal_file_cnt wal_ckpt_cnt wal_dir_bytes wal_node_dirs wal_ls wal_magic_cnt \
         wal_sum_over_dn wal_per_node wal_log_files wal_log_sum wal_log_tail \
         wal_install_err_pat wal_positive_evidence wal_check_logs \
         wal_kill9_dn wal_stop_dn wal_start_dn wal_restart_all wal_wait_replay \
         wal_metric_names wal_metric wal_props_get wal_eff wal_eff_all wal_set \
         wal_blocked_writers wal_heap_ratio wal_oom_cnt wal_object_root wal_object_cnt"
WAL_FNS_PAT=$(printf '%s' "$WAL_FNS" | tr -s '[:space:]' '|' | sed 's/^|//;s/|$//')

echo "=== 1) 语法检查（bash -n 全 skill 的 *.sh）==="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/wal_st.err; then pass_c "bash -n ${f#$SKILL/}"; else fail_c "bash -n ${f#$SKILL/} : $(head -1 /tmp/wal_st.err)"; fi
done < <(find "$SKILL" -name '*.sh' -not -path '*/results/*')

echo "=== 2) 用例矩阵与脚本（cases/cases.tsv ⇔ cases/*/*.sh；未补齐记 [planned]，不算失败）==="
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
N_CASES=${#LINES[@]}                       # 以矩阵**数据行数**为准（空矩阵就是 0，不要被空数组展开成 1 行骗过）
IDS=""
[ "$N_CASES" -gt 0 ] && IDS=$(printf '%s\n' "${LINES[@]}" | cut -f1)
n_ids=$(printf '%s' "$IDS" | grep -c . || true)
[ "$n_ids" = "$N_CASES" ] && pass_c "用例 ID 齐全（矩阵行数=$N_CASES）" || fail_c "用例 ID 有缺失（矩阵行数=$N_CASES，非空 ID 数=$n_ids）"
n_uniq=$(printf '%s\n' "$IDS" | grep . | sort -u | wc -l)
[ "$n_uniq" = "$N_CASES" ] && pass_c "用例 ID 不重复（$N_CASES 条）" || fail_c "用例 ID 有重复（唯一 $n_uniq / 总 $N_CASES）"
[ "$N_CASES" -ge 1 ] && pass_c "用例数=$N_CASES（≥1，期望 27 条 W-00..W-26）" || fail_c "用例数偏少（$N_CASES，期望 ≥1）"
PLANNED_IDS=""; MAP_IDS=()
if [ "$N_CASES" -gt 0 ]; then
  while IFS=$'\t' read -r id script rest; do
    [ -n "$id" ] || continue
    MAP_IDS+=("$id")
    if [ -f "$SKILL/$script" ]; then pass_c "$id 脚本存在（$script）"
    else plan_c "$id 待补齐（$script）"; PLANNED_IDS="$PLANNED_IDS $id"; fi
  done < <(printf '%s\n' "${LINES[@]}")
fi
printf '  -- 矩阵 %s 条：已实现 %s 条 / 待补齐 planned=%s 条（%s）\n' \
  "$N_CASES" "$((N_CASES - planned))" "$planned" "$(printf '%s' "$PLANNED_IDS" | sed 's/^ //')"
# 反向：cases/ 下存在但矩阵未登记的脚本 ⇒ **必须 FAIL**（否则"加了脚本却在集合里静默跳过"会漏测）
n_orphan=0
while IFS= read -r f; do
  rel=${f#$SKILL/}
  grep -qE "[[:space:]]${rel}([[:space:]]|\$)" "$SKILL/cases/cases.tsv" || { fail_c "脚本未登记到 cases.tsv：$rel"; n_orphan=$((n_orphan+1)); }
done < <(find "$SKILL/cases" -name '*.sh' | sort)
[ "$n_orphan" = 0 ] && pass_c "cases/ 下的脚本全部已在 cases.tsv 登记"

echo "=== 3) env.conf 变量完整性（WAL 专项口径）==="
. "$SKILL/conf/env.conf"
for v in CLUSTER_NODES CN_NODES DN_NODES SSH_USER DB_PARENT_DIR SHELL_CLIENT_DIR V_TESTDB BUILD_TAG DB_USER ROOT_PW \
         SCHEMA_RF DATA_RF DATA_CONSENSUS CMP_CANDIDATE_NUM CMP_INTERVAL_MS CMP_EXTRA_CONF CMP_EXTRA_CROSS CMP_EXTRA_WRITE \
         WAL_MODE WAL_ASYNC_FSYNC_MS WAL_SYNC_FSYNC_MS WAL_BUFFER_BYTES WAL_FILE_THRESHOLD_BYTES WAL_MIN_EFF_RATIO \
         WAL_SNAPSHOT_THRESHOLD_BYTES WAL_MAX_SNAPSHOT_NUM WAL_DELETE_PERIOD_MS WAL_THROTTLE_BYTES WAL_COMPRESSION \
         WAL_MAX_NODES WAL_EXTRA_DEFAULT \
         WAL_DEVS WAL_ROWS WAL_BATCHES WAL_WIN_SEC WAL_CLOSE_WIN_SEC \
         WAL_KILL_WAIT_SEC WAL_REPLAY_WIN_SEC WAL_KILL_MODE \
         WAL_ROTATE_THRESHOLD_SMALL WAL_BUFFER_SMALL WAL_ROTATE_MIN_FILES \
         WAL_COMPRESS_RATIO_MIN WAL_COMPRESS_DEVS WAL_COMPRESS_ROWS WAL_COMPRESS_BATCHES \
         WAL_CLEAN_PERIOD_SMALL_MS WAL_CLEAN_WIN_SEC \
         WAL_THROTTLE_SMALL WAL_PRESSURE_DEVS WAL_PRESSURE_ROWS WAL_PRESSURE_WIN_SEC WAL_HEAP_WARN_RATIO \
         DN_METRIC_PORT USE_FRAMEWORK DN_DOWN_WAIT_SEC DN_RECOVER_WAIT_SEC SQL_TIMEOUT_SEC; do
  [ -n "${!v:-}" ] && pass_c "env: $v=${!v}" || fail_c "env: $v 未定义/为空"
done
printf '%s' "$CMP_EXTRA_CONF" | grep -q 'enable_seq_space_compaction=true' && pass_c "默认组合开启 seq 合并" || fail_c "默认组合未开启 seq 合并"
printf '%s' "$CMP_EXTRA_CONF" | grep -q 'inner_compaction_candidate_file_num' && pass_c "默认组合含候选文件数" || fail_c "默认组合缺候选文件数"
printf '%s' "$CMP_EXTRA_CROSS" | grep -q 'enable_cross_space_compaction=true' && pass_c "跨空间组合开启 cross" || fail_c "跨空间组合未开启 cross"
# WAL 约定：默认组合必须带上 wal_mode 与压缩开关；且**默认不许是 DISABLE**（集群下会被拒，只用于 W-02 负向用例）
printf '%s' "$WAL_EXTRA_DEFAULT" | grep -q 'wal_mode=' && pass_c "WAL_EXTRA_DEFAULT 含 wal_mode" || fail_c "WAL_EXTRA_DEFAULT 缺 wal_mode"
printf '%s' "$WAL_EXTRA_DEFAULT" | grep -q 'enable_wal_compression=' && pass_c "WAL_EXTRA_DEFAULT 含 enable_wal_compression" || fail_c "WAL_EXTRA_DEFAULT 缺 enable_wal_compression"
printf '%s' "$WAL_EXTRA_DEFAULT" | grep -q 'wal_mode=DISABLE' && fail_c "WAL_EXTRA_DEFAULT 默认写了 wal_mode=DISABLE（集群下 DN 直接起不来）" || pass_c "WAL_EXTRA_DEFAULT 默认不含 wal_mode=DISABLE"
# env.conf 赋值行语法：`VAR="x"#注释`（# 前缺空格）会被 bash 当成"临时赋值 + 命令"执行 ——
# 变量**根本没被设置**，source 时还会报 `…: command not found`（WAL_REPLAY_WIN_SEC 就踩过）。
# 这类坑只在运行时暴露（`${VAR:-默认}` 会掩盖），所以静态抓出来。
bad_asg=$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=(".*"|[^[:space:]#]*)#' "$SKILL/conf/env.conf" 2>/dev/null | tr '\n' ';')
[ -z "$bad_asg" ] && pass_c "env.conf 赋值行语法正常（无 '\"…\"#' 注释粘连）" || fail_c "env.conf 赋值行把注释粘在值后面（# 前缺空格 ⇒ 该变量未生效，改用空格分隔）：$bad_asg"
[ "$WAL_MODE" != "DISABLE" ] && pass_c "env 默认 WAL_MODE=$WAL_MODE（DISABLE 只用于 W-02 负向用例）" || fail_c "env 默认 WAL_MODE=DISABLE（其余 26 条用例都会起不来）"
# WAL skill 的默认版本（换环境只改 env.conf，这里锁住"默认是 RC7"这一约定）
grep -qE '^V_TESTDB="\$\{V_TESTDB:-v20121rc7_' "$SKILL/conf/env.conf" && pass_c "env.conf 默认版本是 RC7（v20121rc7_*）" || fail_c "env.conf 默认版本不是 RC7"

echo "=== 4) helper 存在性（lib/common.sh + lib/cmp.sh 基线）==="
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
          cmp_check_logs_on cmp_perf_record dn_state cluster_stop cluster_start; do
  chk "函数 $fn 已定义" "declare -F $fn"
done

echo "=== 5) 断言框架行为（含负向：故意失败必须 fail_flag>0）==="
fail_flag=0; v_warnMessage=""; OUT=/tmp/wal_st_assert.out; : >"$OUT"
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

echo "=== 6b) WAL 观测层：钩子默认空 + wal_ext.sh 可用 + 不自动改默认行为 ==="
# 钩子必须是"纯增量"：默认空 ⇒ check_logs 行为与其它 skill 的版本一致（合并/TTL/元数据/CRUD 不受影响）
printf '%s' "${CMP_ERR_PAT_CUSTOM:-}" | grep -q . && fail_c "source common.sh/cmp.sh 后 CMP_ERR_PAT_CUSTOM 已非空（会改变默认行为）" || pass_c "CMP_ERR_PAT_CUSTOM 默认空"
printf '%s' "${CMP_POSITIVE_EVIDENCE_FN:-}" | grep -q . && fail_c "source common.sh/cmp.sh 后 CMP_POSITIVE_EVIDENCE_FN 已非空（会改变默认行为）" || pass_c "CMP_POSITIVE_EVIDENCE_FN 默认空"
grep -q '合并任务累计' "$SKILL/lib/common.sh" && pass_c "check_logs 仍保留合并正证据（钩子未设置时的回退路径）" || fail_c "check_logs 的合并正证据回退路径缺失"
chk "lib/wal_ext.sh 存在" "[ -f '$SKILL/lib/wal_ext.sh' ]"
. "$SKILL/lib/wal_ext.sh" 2>/dev/null
for fn in $WAL_FNS; do
  chk "函数 $fn 已定义（wal_ext.sh）" "declare -F $fn"
done
printf '%s' "$(wal_err_pat_extra 2>/dev/null)" | grep -q 'WAL' && pass_c "wal_err_pat_extra 返回 WAL 专属正则（可用）" || fail_c "wal_err_pat_extra 未返回 WAL 专属正则"
printf '%s' "${CMP_ERR_PAT_CUSTOM:-}" | grep -q . && fail_c "source wal_ext.sh 后 CMP_ERR_PAT_CUSTOM 被自动设置（必须用例显式 opt-in）" || pass_c "source wal_ext.sh 不导出 CMP_ERR_PAT_CUSTOM"
printf '%s' "${CMP_POSITIVE_EVIDENCE_FN:-}" | grep -q . && fail_c "source wal_ext.sh 后 CMP_POSITIVE_EVIDENCE_FN 被自动设置（必须用例显式 opt-in）" || pass_c "source wal_ext.sh 不设置 CMP_POSITIVE_EVIDENCE_FN"

echo "=== 6c) WAL 集合清单（run_all.sh：12 个集合，显式 ID 清单逐字核对）==="
# 集合名与 ID 清单**必须与 run_all.sh 的 case_in_set 逐字一致**（改集合必须同步改这里）
for pair in "smoke:W-00" "mode:W-01 W-02 W-03" "recover:W-04 W-05 W-06 W-07" "file:W-08 W-09 W-10" \
            "compress:W-11 W-12 W-13" "cleanup:W-14 W-15 W-16" "mem:W-17 W-18" "object:W-19 W-20" \
            "param:W-21 W-22" "observe:W-23 W-24" "ha:W-25 W-26"; do
  s=${pair%%:*}; ids=${pair#*:}
  grep -qF "set_ids=\"$ids\"" "$SKILL/tools/run_all.sh" && pass_c "run_all.sh：$s = $ids" || fail_c "run_all.sh：$s 集合不是显式 '$ids'"
done
grep -q 'smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all)' "$SKILL/tools/run_all.sh" && pass_c "run_all.sh：--set 白名单含全部 12 个集合名" || fail_c "run_all.sh：--set 白名单与 12 个集合名不一致"
grep -qE '^[[:space:]]*all\)[[:space:]]*return 0' "$SKILL/tools/run_all.sh" && pass_c "run_all.sh：all = 矩阵全量（无条件 return 0）" || fail_c "run_all.sh：all 分支不是无条件全量"
# all 不能漏项：11 个显式集合的**并集必须覆盖矩阵全部 ID**（新增用例必须显式决定归属，否则 all 之外永远跑不到）
map_sorted=$(printf '%s\n' "${MAP_IDS[@]}" | sed '/^$/d' | sort -u)
set_sorted=$(grep -oE 'set_ids="[^"]*"' "$SKILL/tools/run_all.sh" | sed 's/^set_ids="//;s/"$//' | tr ' ' '\n' | sed '/^$/d' | sort -u)
miss=$(comm -23 <(printf '%s\n' "$map_sorted") <(printf '%s\n' "$set_sorted") | tr '\n' ' ')
extra=$(comm -13 <(printf '%s\n' "$map_sorted") <(printf '%s\n' "$set_sorted") | tr '\n' ' ')
[ -z "$miss" ] && pass_c "集合并集覆盖矩阵全部 $N_CASES 条 ID（all 无漏项）" || fail_c "这些矩阵 ID 不属于任何显式集合（all 漏项风险）：$miss"
[ -z "$extra" ] && pass_c "集合里没有矩阵之外的 ID（无遗留集合项）" || fail_c "集合里登记了矩阵之外的 ID：$extra"
grep -qE 'W-[0-9]\[0-9\]' "$SKILL/tools/run_all.sh" && fail_c "run_all.sh 的 case_in_set 里仍有编号区间通配" || pass_c "run_all.sh 的 case_in_set 已无编号区间通配"

echo "=== 7) 静态坑检查 ==="
# ① 同一条 local 里"先赋值、后面在算术展开中引用"（`set -u` 下展开先于赋值 ⇒ unbound，函数静默返回空）
#    只在本条 local 语句内查找（用 [^;&|] 挡住 `;` 之后的独立语句，避免误报 `local a=$1 …; b=$((…a…))`）；
#    先 `sed 's/#.*//'` 去掉注释（lib/common.sh 的说明性注释里就写了这个反例，不剥会误报）
LOCAL_ARITH_PAT='local[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=\$[0-9A-Za-z_]+[^;&|]*\$\(\([^)]*\1'
n_local=0
while IFS= read -r f; do
  hit=$(sed 's/#.*//' "$f" | grep -nE "$LOCAL_ARITH_PAT" 2>/dev/null | head -2 | tr '\n' ';')
  [ -z "$hit" ] || { fail_c "${f#$SKILL/} 同一条 local 内引用算术变量（改为另起一句赋值）：$hit"; n_local=$((n_local+1)); }
done < <(find "$SKILL/lib" "$SKILL/cases" -name '*.sh' ! -name 'selftest.sh' 2>/dev/null | sort)
[ "$n_local" = 0 ] && pass_c "无 'local a=\$1 … \$((…a…))' 同句引用问题（已排除注释行）"
# ② 全角括号误用（`$（` 会被当成普通字符 ⇒ 断言永远为真）
if grep -rn --exclude=selftest.sh '\$（' "$SKILL/lib" "$SKILL/cases" "$SKILL/tools" 2>/dev/null | grep -q .; then
  fail_c "存在全角括号误用 \$（"; else pass_c "无全角括号误用"; fi
# ③ harness/用例脚本统一带 set -uo pipefail（lib/ 是被 source 的，不在本检查内）
n_noset=0; n_sh=0
for f in "$SKILL"/tools/*.sh "$SKILL"/cases/*/*.sh; do
  [ -f "$f" ] || continue                  # 无匹配时 glob 保留字面量，这里挡掉
  n_sh=$((n_sh+1))
  grep -q 'set -uo pipefail' "$f" || { fail_c "${f#$SKILL/} 缺 set -uo pipefail"; n_noset=$((n_noset+1)); }
done
[ "$n_noset" = 0 ] && pass_c "set -uo pipefail 存在（tools/*.sh + cases/*/*.sh 共 $n_sh 个）"
# ④ WAL 约定：用例 ID 一律 W- 前缀；用例里的库名一律 root.wal*（不与其它 skill / 长回归互相干扰）
n_bad_id=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$id" in W-*) ;; *) fail_c "用例 ID 未用 W- 前缀：$id"; n_bad_id=$((n_bad_id+1)) ;; esac
done < <(printf '%s\n' "$IDS")
[ "$n_bad_id" = 0 ] && pass_c "用例 ID 前缀统一 W-"
bad_db=$(grep -rhoE 'root\.[A-Za-z0-9_]+' "$SKILL"/cases/*/*.sh 2>/dev/null | grep -vE '^root\.wal' | sort -u | tr '\n' ' ')
[ -z "$bad_db" ] && pass_c "用例库名统一 root.wal*" || fail_c "用例里存在非 root.wal* 的库名：$bad_db"
# ⑤ WAL 专属：除 W-02 负向用例外，任何用例不得写 wal_mode=DISABLE（集群下 DN 启动直接失败）
#    先去掉注释（说明性文字里常出现这句话），只看真正的赋值 ⇒ 不误报
n_disable=0
while IFS= read -r f; do
  sed 's/#.*//' "$f" | grep -qE '(wal_mode|WAL_MODE)=DISABLE' \
    && { fail_c "${f#$SKILL/} 出现 wal_mode=DISABLE（仅 W-02 wal_mode_disable_rejected.sh 允许）"; n_disable=$((n_disable+1)); }
done < <(find "$SKILL/cases" -name '*.sh' ! -name 'wal_mode_disable_rejected.sh' | sort)
[ "$n_disable" = 0 ] && pass_c "wal_mode=DISABLE 未被误用（W-02 白名单之外 0 处）"
# ⑥ WAL 专属：凡调用 wal_* 观测函数的用例，必须 source lib/wal_ext.sh（否则运行期 command not found）
n_nosrc=0; n_waluse=0
for f in "$SKILL"/cases/*/*.sh; do
  [ -f "$f" ] || continue
  grep -qE "\b($WAL_FNS_PAT)\b" "$f" || continue
  n_waluse=$((n_waluse+1))
  grep -q 'lib/wal_ext.sh' "$f" || { fail_c "${f#$SKILL/} 调用了 wal_* 观测函数但未 source lib/wal_ext.sh"; n_nosrc=$((n_nosrc+1)); }
done
[ "$n_nosrc" = 0 ] && pass_c "调用 wal_* 的用例都已 source lib/wal_ext.sh（$n_waluse 个脚本）"
# ⑦ 每条用例统一收尾：cmp_case_init（初始化）+ cmp_case_finish（收尾）+ 日志/一致性检查
n_missing=0; n_case_sh=0
for f in "$SKILL"/cases/*/*.sh; do
  [ -f "$f" ] || continue
  n_case_sh=$((n_case_sh+1))
  b=${f#$SKILL/}
  grep -q 'cmp_case_init' "$f" || { fail_c "$b 未调用 cmp_case_init（用例初始化）"; n_missing=$((n_missing+1)); }
  grep -q 'cmp_case_finish' "$f" || { fail_c "$b 未调用 cmp_case_finish（统一收尾）"; n_missing=$((n_missing+1)); }
  grep -qE 'post_checks|check_sync_lag_on|check_logs|wal_check_logs' "$f" || { fail_c "$b 收尾未做日志/一致性检查"; n_missing=$((n_missing+1)); }
done
[ "$n_missing" = "0" ] && pass_c "用例统一收尾：已检查 $n_case_sh 个脚本，全部调用（矩阵 $N_CASES 条 / planned $planned 条）" || fail_c "有脚本未满足统一收尾约定（检查 $n_case_sh 个）"

echo "=== 9) EXTRA_CONF 覆盖语义（同键后者胜；回归 2026-10-21 W-08 的 3 条假 FAIL）==="
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
echo "=== 自检汇总：ok=$ok failed=$bad planned=$planned ==="
[ "$bad" = "0" ] || exit 1
