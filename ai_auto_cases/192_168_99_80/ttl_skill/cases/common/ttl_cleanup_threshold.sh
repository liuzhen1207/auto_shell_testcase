#!/bin/bash
# ============================================================================
# TP-02 树模型 TTL 清理阈值 / 写放大守卫（文件级）
#
#   覆盖两类文件与两类参数组合：
#     A) 全过期文件（文件内设 TTL 的设备全部过期）→ FULLY_DIRTY 整文件删除
#     B) 部分过期文件（1/N 设备过期）+ max_expired_time=INF + ratio=极小正数 → 按比例门控应清理
#     C) 写放大守卫：清理完成后，"已无脏数据"的文件不应再被反复 settle 重写（4 个检查周期内计数不增长）
#     D) 缺陷复现：expired_data_ratio=0.0 时，deletedDeviceRatio(0.0) >= 0.0 恒真
#        ⇒ 零脏数据文件每个检查周期都被 settle 重写（RC4 实测 21 代/15s）——本用例把这条做成回归门禁
#
#   为什么用 max_expired_time=9223372036854775807（INF）：
#     RC4 的 SettleSelectorImpl L294 把本意的 `3 * ttl` 写成了 `ttl`，导致
#     `min(max_expired_time, ttl)` 恒被"设备已过期"满足 → "过期太久"强制分支恒真、比例门控被短路。
#     只有 max_expired_time=INF 时比例才真正参与判定（详见 docs/CALIBRATION.md 0.6）。
#
# 用法： bash ttl_cleanup_threshold.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_cleanup_threshold_${DATA_CONSENSUS}"

TTL_MS=${TTL_TH_MS:-30000}                 # 过期的观察 TTL
WAIT=$(( TTL_MS/1000 + 25 ))               # 等过期（+25s 抵消节点间时钟差）
GUARD_INTERVALS=4                          # 写放大守卫观察的检查周期数
GUARD_WAIT=$(( TTL_CHECK_INTERVAL_MS/1000 * GUARD_INTERVALS + 15 ))
INF=9223372036854775807
TINY=0.000001

DBF=root.th_full      # A: 全过期
DBP=root.th_part      # B/C: 部分过期 + 写放大守卫
DBC=root.th_zero      # D: ratio=0.0 的写放大复现

log "--- 集群准备（Phase1: max_expired_time=INF, expired_data_ratio=$TINY, ttl_check_interval=$TTL_CHECK_INTERVAL_MS） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=$TINY ttl_cluster_prepare

log "--- A) 全过期文件 → 应整文件删除（FULLY_DIRTY） ---"
sq "create database $DBF;" >/dev/null
sq "create timeseries $DBF.d1.s1 with datatype=int64;" >/dev/null
sq "set ttl to $DBF  $TTL_MS;" >/dev/null
tA=$(now_ms); sq "insert into $DBF.d1(time,s1) values($tA, 1);" >/dev/null
ensure_closed "$DBF" 3 25 || warn "A: 有 DN 的 TsFile 未落盘（该副本不参与选择，断言只按已落盘副本算）"
log "  A 各 DN 落盘(Async close)条数: $(ttl_close_snapshot "$DBF")；TsFile 数: $(tsfile_counts_all "$DBF")"
sleep "$WAIT"
c=$(scalar "$(sq "select count(*) from $DBF.d1;")"); c=${c:-0}
assert_scalar "A 全过期数据不可见" "$c" "0"
# 等各"已落盘"副本把整文件删掉：RC4 实测某副本可能晚到 5 分钟（Settle 任务排队 + flush 延迟），
# 所以这里给 CLEANUP_WAIT_SEC + 240s 的窗口，并按"已落盘副本"判定。
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC + 240 )); allgone=0
while (( $(date +%s) < deadline )); do
  allgone=1; h=""
  for h in "${DN[@]}"; do
    [ "$(ttl_close_cnt "$h" "$DBF")" -gt 0 ] || continue          # 未落盘的副本不参与判定
    n=$(tsfile_count "$h" "$DBF"); n=${n:-0}
    [ "$n" -eq 0 ] || allgone=0
  done
  [ "$allgone" = 1 ] && break
  log "  A 等整文件删除：TsFile 数=$(tsfile_counts_all "$DBF") 落盘=$(ttl_close_snapshot "$DBF")"
  sleep 10
done
fdc=$(sum_over_db settle_fully_dirty_cnt "$DBF")
log "  A 该库 settle 任务: $(sum_over_db settle_task_for_db "$DBF")，其中 fully_dirty 任务=$fdc"
[ "$fdc" -gt 0 ] && pass "A 全过期文件被判定为 FULLY_DIRTY 并清理（fully_dirty 任务 $fdc 个）" \
                 || fail "A 未见 FULLY_DIRTY settle 任务（TsFile=$(tsfile_counts_all "$DBF")）"
[ "$allgone" = 1 ] && pass "A 已落盘副本上整文件被删除（TsFile 数均为 0）" \
                   || fail "A 整文件未删净：TsFile=$(tsfile_counts_all "$DBF")，落盘=$(ttl_close_snapshot "$DBF")"

log "--- B) 部分过期文件 + max_expired_time=INF + ratio=$TINY → 按比例门控应清理 ---"
sq "create database $DBP;" >/dev/null
for d in d1 d2; do sq "create timeseries $DBP.$d.s1 with datatype=int64;" >/dev/null; done
sq "set ttl to $DBP.d1 $TTL_MS;" >/dev/null          # 只有 d1 有 TTL → 过期占比 ≤ 1/2 ≥ 1e-6
tB=$(now_ms)
for d in d1 d2; do sq "insert into $DBP.$d(time,s1) values($tB, 1);" >/dev/null; done
ensure_closed "$DBP" 3 25 || warn "B: 有 DN 的 TsFile 未落盘"
log "  B 各 DN 落盘条数: $(ttl_close_snapshot "$DBP")；TsFile 数: $(tsfile_counts_all "$DBP")"
sleep "$WAIT"
c=$(scalar "$(sq "select count(*) from $DBP.d1;")"); c=${c:-0}
assert_scalar "B 过期设备 d1 不可见" "$c" "0"
c=$(scalar "$(sq "select count(*) from $DBP.d2;")"); c=${c:-0}
assert_scalar "B 未过期设备 d2 数据仍在" "$c" "1"
res=$(wait_settle_inc "$DBP" 1 "$CLEANUP_WAIT_SEC") || true
log "  B 该库 settle 任务: $res"
[ "$(sum_over_db settle_task_for_db "$DBP")" -gt 0 ] && pass "B 部分过期文件按比例被选中并 settle（比例门控 + INF 组合）" \
                                                     || fail "B 部分过期文件在 ratio=$TINY 下未被清理"

log "--- C) 写放大守卫：清理完成后 $GUARD_INTERVALS 个检查周期内不应再反复 settle ---"
b=$(sum_over_db settle_task_for_db "$DBP"); bgen=$(tsfile_gen_max "$DBP")
log "  C 基线：settle=$b，最大文件代=$bgen，落盘=$(ttl_close_snapshot "$DBP")；观察 ${GUARD_WAIT}s（约 $GUARD_INTERVALS 个检查周期）"
sleep "$GUARD_WAIT"
a=$(sum_over_db settle_task_for_db "$DBP"); agen=$(tsfile_gen_max "$DBP")
log "  C 观察后：settle=$a（+$((a-b))），最大文件代=$agen（+$((agen-bgen))）"
[ $((a-b)) -eq 0 ] && pass "C ratio=$TINY 时零脏数据文件没有被反复重写（settle 无增长）" \
                   || fail "C ratio=$TINY 时仍被反复重写：settle +$((a-b))，文件代 +$((agen-bgen))"

log "--- D) 缺陷复现：expired_data_ratio=0.0 时零脏数据文件会被反复 settle 重写 ---"
cluster_stop
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=0.0 cluster_write_conf
cluster_start
sq "create database $DBC;" >/dev/null
for d in d1 d2 d3; do sq "create timeseries $DBC.$d.s1 with datatype=int64;" >/dev/null; done
sq "set ttl to $DBC.d1 $TTL_MS;" >/dev/null
tD=$(now_ms)
for d in d1 d2 d3; do sq "insert into $DBC.$d(time,s1) values($tD, 1);" >/dev/null; done
ensure_closed "$DBC" 3 25 || warn "D: 有 DN 的 TsFile 未落盘"
sleep "$WAIT"
res=$(wait_settle_inc "$DBC" 1 "$CLEANUP_WAIT_SEC") || true
log "  D 首次清理: $res"
b2=$(sum_over_db settle_task_for_db "$DBC"); bgen2=$(tsfile_gen_max "$DBC")
log "  D 基线（首次清理后）：settle=$b2，最大文件代=$bgen2；观察 ${GUARD_WAIT}s"
sleep "$GUARD_WAIT"
a2=$(sum_over_db settle_task_for_db "$DBC"); agen2=$(tsfile_gen_max "$DBC")
log "  D 观察后：settle=$a2（+$((a2-b2))），最大文件代=$agen2（+$((agen2-bgen2))）"
[ $((a2-b2)) -eq 0 ] && pass "D ratio=0.0 时零脏数据文件没有被反复重写（settle 无增长）" \
                     || fail "D ratio=0.0 时零脏数据文件被反复 settle 重写：settle +$((a2-b2))，文件代 +$((agen2-bgen2))（缺陷：deletedDeviceRatio(0.0) >= 0.0 恒真）"
for h in "${DN[@]}"; do log "  D $h [TTL] 记录: $(ttl_last_line_for_db "$h" "$DBC" | tr '\n' ' ' | cut -c1-190)"; done

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DBP.d2;" tree
ttl_case_finish "" tree ""
