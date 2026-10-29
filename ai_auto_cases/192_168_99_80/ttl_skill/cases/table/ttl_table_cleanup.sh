#!/bin/bash
# ============================================================================
# TB-05 表模型 TTL 清理阈值 / 写放大守卫
#
#   与 TP-02（树模型）对应，验证表模型走的是同一套 settle 选择逻辑
#   （`SettleSelectorImpl` 里表模型用 `DataNodeTTLCache.getTTLForTable(storageGroupName, tableName)`）：
#     A) 表数据全过期 → FULLY_DIRTY 整文件删除（TsFile 归零 + settle 删除日志）
#     B) 表 TTL='INF' 的表不参与清理（负向：同库另一张已过期表被清理，INF 表数据仍在）
#     C) 写放大守卫：清理完成后"零脏数据"文件不应被反复 settle 重写（4 个检查周期内计数不增长）
#     D) 缺陷复现：expired_data_ratio=0.0 时 deletedDeviceRatio(0.0) >= 0.0 恒真
#        ⇒ 零脏数据文件每个检查周期被重写（表模型同样命中）
#
#   max_expired_time=INF 的原因同 TP-02：RC4 的 L294 阈值笔误会让"过期太久"分支恒真、
#   短路 expired_data_ratio（详见 docs/CALIBRATION.md 0.6）。
#
# 用法： bash ttl_table_cleanup.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_table_cleanup_${DATA_CONSENSUS}"

DB=ttl_cleanup        # 表模型库名不带 root. 前缀
# 表模型每条语句一次 CLI 会话（use + 语句）较慢，TTL 太小会让"未到期"断言本身失效（曾用 30s 踩坑）
TTL_MS=${TTL_TB_MS:-60000}
WAIT=$(( TTL_MS/1000 + 25 ))
GUARD_INTERVALS=4
GUARD_WAIT=$(( TTL_CHECK_INTERVAL_MS/1000 * GUARD_INTERVALS + 15 ))
INF=9223372036854775807
TINY=0.000001

tq(){ sql_lines_table "use $DB;" "$@"; }
tq1(){ tq "$1"; }

log "--- 集群准备（Phase1: max_expired_time=INF, expired_data_ratio=$TINY, ttl_check_interval=$TTL_CHECK_INTERVAL_MS） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=$TINY ttl_cluster_prepare

log "--- 建库 + 两张表：t_exp(ttl=$TTL_MS, 会过期) / t_inf(ttl='INF', 永不过期) ---"
out=$(sql_lines_table "create database $DB;"); assert_contains "建库成功" "$out" "successfully"
out=$(tq1 "create table t_exp (dev string tag, v double field) with (ttl=$TTL_MS);"); assert_contains "建表 t_exp 成功" "$out" "successfully"
out=$(tq1 "create table t_inf (dev string tag, v double field) with (ttl='INF');");   assert_contains "建表 t_inf 成功" "$out" "successfully"
out=$(tq "insert into t_exp (time, dev, v) values ($(now_ms), 'd1', 1);" \
           "insert into t_inf (time, dev, v) values ($(now_ms), 'k1', 9);")
assert_contains "写入 2 行成功" "$out" "successfully"
# "未到期可见"必须在写完后**立刻**断言：表模型一次会话要好几秒，TTL 窗口会被后续 flush 步骤吃掉
c=$(scalar "$(sql_lines_table "select count(*) from $DB.t_exp;")"); assert_scalar "t_exp 未到期行数" "${c:-0}" "1"
c=$(scalar "$(sql_lines_table "select count(*) from $DB.t_inf;")"); assert_scalar "t_inf(INF) 行数" "${c:-0}" "1"
ensure_closed "$DB" 3 25 || warn "有 DN 的 TsFile 未落盘（该副本不参与选择）"
log "  各 DN 落盘(Async close)条数: $(ttl_close_snapshot "$DB")"
log "  TsFile 数(各 DN): $(tsfile_counts_all "$DB")"

log "--- A) 等过期后：过期表不可见，且应被物理清理 ---"
sleep "$WAIT"
c=$(scalar "$(sql_lines_table "select count(*) from $DB.t_exp;")"); assert_scalar "A 过期表数据不可见" "${c:-0}" "0"
c=$(scalar "$(sql_lines_table "select count(*) from $DB.t_inf;")"); assert_scalar "A t_inf(INF) 数据仍在" "${c:-0}" "1"
res=$(wait_settle_inc "$DB" 1 "$CLEANUP_WAIT_SEC") || true
log "  A 该库 settle 任务: $res"
[ "$(sum_over_db settle_task_for_db "$DB")" -gt 0 ] && pass "A 过期表数据被 settle 清理" \
                                                    || fail "A 过期表数据未被清理"
for h in "${DN[@]}"; do log "  A $h [TTL] 记录: $(ttl_last_line_for_db "$h" "$DB" | tr '\n' ' ' | cut -c1-190)"; done

log "--- C) 写放大守卫：清理完成后 $GUARD_INTERVALS 个检查周期内不应再反复 settle ---"
b=$(sum_over_db settle_task_for_db "$DB"); bgen=$(tsfile_gen_max "$DB")
log "  C 基线：settle=$b，最大文件代=$bgen；观察 ${GUARD_WAIT}s"
sleep "$GUARD_WAIT"
a=$(sum_over_db settle_task_for_db "$DB"); agen=$(tsfile_gen_max "$DB")
log "  C 观察后：settle=$a（+$((a-b))），最大文件代=$agen（+$((agen-bgen))）"
[ $((a-b)) -eq 0 ] && pass "C ratio=$TINY 时表模型零脏数据文件没有被反复重写" \
                   || fail "C ratio=$TINY 时表模型仍被反复重写：settle +$((a-b))，文件代 +$((agen-bgen))"
c=$(scalar "$(sql_lines_table "select count(*) from $DB.t_inf;")"); assert_scalar "C t_inf 数据仍完好" "${c:-0}" "1"

log "--- D) 缺陷复现：expired_data_ratio=0.0 时零脏数据文件被反复 settle 重写（表模型） ---"
cluster_stop
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=0.0 cluster_write_conf
cluster_start
out=$(sql_lines_table "create database ${DB}_z;"); assert_contains "D 建库成功" "$out" "successfully"
# 注意：必须显式 use 到 D 相自己的库！早期版本这里误用了 tq1（= use $DB），把表建到了主库，
# 而插入用的是 ${DB}_z，于是插入全部失败、t_keep 永远查不到（且 `use` 语句自带的 successfully 会骗过弱断言）。
tqz(){ sql_lines_table "use ${DB}_z;" "$@"; }
out=$(tqz "create table t_z (dev string tag, v double field) with (ttl=$TTL_MS);");   assert_contains "D 建表 t_z(会过期) 成功" "$out" "successfully"
out=$(tqz "create table t_keep (dev string tag, v double field) with (ttl='INF');");   assert_contains "D 建表 t_keep(INF) 成功" "$out" "successfully"
out=$(sql_lines_table "use ${DB}_z; show tables;")
assert_contains "D 表确实建在 ${DB}_z" "$out" "t_keep"
assert_contains "D 表确实建在 ${DB}_z（t_z）" "$out" "t_z"
# 同库里放一张 ttl='INF' 的表：过期表被清理后，文件里会剩下"没有任何过期设备"的数据，
# 正是缺陷 2（deletedDeviceRatio(0.0) >= 0.0 恒真）反复重写的对象。
out=$(tqz \
      "insert into t_z (time, dev, v) values ($(now_ms), 'd1', 1);" \
      "insert into t_z (time, dev, v) values ($(now_ms), 'd2', 2);" \
      "insert into t_keep (time, dev, v) values ($(now_ms), 'k1', 9);")
# 注意：不能只断言"输出里含 successfully"——3 条 insert 里只要有 1 条成功就会出现该串（曾因此误判：
# D 相后面读不到 t_keep 数据，实际是第 3 条 insert 没执行成功，而不是数据丢失/不可见）。
nok=$(printf '%s\n' "$out" | grep -c 'successfully')
[ "$nok" -ge 3 ] && pass "D 三条写入均成功（successfully × $nok）" || fail "D 写入未全部成功（只看到 $nok 次 successfully）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
tk_now=$(scalar "$(sql_lines_table "select count(*) from ${DB}_z.t_keep;")"); tk_now=${tk_now:-0}
assert_scalar "D 写入后 t_keep 立即可见" "$tk_now" "1"
ensure_closed "${DB}_z" 3 25 >/dev/null 2>&1 || true
sleep "$WAIT"
res=$(wait_settle_inc "${DB}_z" 1 "$CLEANUP_WAIT_SEC") || true
log "  D 首次清理: $res"
# ttl='INF' 的表数据必须仍可查。注意：ratio=0.0 时该文件每 5s 被重写一次，**读取可能撞上重写窗口返回空**，
# 所以这里轮询而不是单次取样（独立诊断 tools/probe_zero_ratio_dataloss.sh 已确认数据不会丢：
# 同场景下 t_keep=1 且非过期设备数据完好，settle 只在被反复重写）。
tk_raw=""; tk=0; dl=$(( $(date +%s) + 60 ))
while (( $(date +%s) < dl )); do
  tk_raw=$(sql_lines_table "select count(*) from ${DB}_z.t_keep;")
  tk=$(scalar "$tk_raw"); tk=${tk:-0}
  [ "$tk" = "1" ] && break
  sleep 5
done
if [ "$tk" = "1" ]; then
  pass "D INF 表数据仍在（轮询确认，一次 settle 重写循环未影响非过期数据）"
else
  log "  D t_keep 查询原始输出: $(printf '%s' "$tk_raw" | tr '\n' ' ' | cut -c1-200)"
  fail "D INF 表数据查询为空（count=$tk）；对照 probe_zero_ratio_dataloss 的 NO_DATA_LOSS 结论，这更像'重写窗口内瞬时读取为空'，需人工确认"
fi
b2=$(sum_over_db settle_task_for_db "${DB}_z"); bgen2=$(tsfile_gen_max "${DB}_z")
log "  D 基线（首次清理后）：settle=$b2，最大文件代=$bgen2，TsFile=$(tsfile_counts_all "${DB}_z")；观察 ${GUARD_WAIT}s"
sleep "$GUARD_WAIT"
a2=$(sum_over_db settle_task_for_db "${DB}_z"); agen2=$(tsfile_gen_max "${DB}_z")
log "  D 观察后：settle=$a2（+$((a2-b2))），最大文件代=$agen2（+$((agen2-bgen2))）"
[ $((a2-b2)) -eq 0 ] && pass "D ratio=0.0 时表模型零脏数据文件没有被反复重写" \
                     || fail "D ratio=0.0 时表模型零脏数据文件被反复 settle 重写：settle +$((a2-b2))，文件代 +$((agen2-bgen2))（deletedDeviceRatio(0.0) >= 0.0 恒真）"

log "--- 收尾三件套 ---"
post_checks "select count(*) from ${DB}.t_inf;" table
ttl_case_finish "" table ""
