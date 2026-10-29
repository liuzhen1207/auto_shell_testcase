#!/bin/bash
# ============================================================================
# CO-04 冒烟：跨空间合并（cross space compaction）+ `min_cross_compaction_unseq_file_level` 参数功能
#
#   背景（源码依据，IoTDBConfig / RewriteCrossSpaceCompactionSelector:306）：
#     if (unseqFile.getTsFileSize() < targetCompactionFileSize
#         && unseqFileName.getInnerCompactionCnt() < min_cross_compaction_unseq_file_level) return false;
#   即：**小 unseq 文件必须先经过内部合并（level ≥ min_cross_compaction_unseq_file_level，默认 1）
#   才会被跨空间合并选中**，否则只能等它涨到 target_compaction_file_size(默认 2GB)。
#   第一版用例直接开三类合并等 cross，90s 内毫无动静 —— 不是缺陷，是这条规则（已实测确认）。
#
#   因此本用例分两相，把这个参数"负向 + 正向"都测到：
#     Phase A（负向，min_cross_compaction_unseq_file_level=1 默认值）：
#       写 seq 区间 + 与之重叠的更早批次（落 unseq，每 region 只有 1 个 unseq 文件 ⇒ 内部合并也升不了级）
#       → 热开三类合并 → 断言 **inner 合并有推进**（说明合并机制是活的）但 **cross finishes 不增**（被该参数拦住）
#     Phase B（正向，改成 0 后重启，数据保留）：
#       同样的 seq/unseq 文件 → 跨空间合并应把 unseq 合并进 seq（unseq 归零、cross finishes 增加）、
#       数据指纹不变（重叠区间的取值必须正确）
#   判据：A 相负向成立 + B 相正向成立 + 无 overlap 异常 + 无卡死 + 收尾三件套
# 用法： bash co_cross_space.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_cross_space_${DATA_CONSENSUS}"

DB=root.cocross
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-90}
WIN_A=${CO_CROSS_NEG_WIN:-60}

# 通配路径上不能把多个聚合写进一条 SQL（`select count(s1), sum(s1), min(s1), max(s1) from db.**`
# 报 `701: Raw data and aggregation hybrid query is not supported`），所以分开查再拼成指纹
co04_fp(){ local db=$1 c s mn mx
  c=$(row_sum "$(sq "select count(s1) from $db.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $db.**;")")
  mn=$(row_sum "$(sq "select min_value(s1) from $db.**;")")
  mx=$(row_sum "$(sq "select max_value(s1) from $db.**;")")
  echo "count=$c sum=$s min=$mn max=$mx"; }

log "--- 集群准备（Phase A：三类合并先关，min_cross_compaction_unseq_file_level=1）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=1" cmp_cluster_prepare

log "--- 造数据：seq 区间 + 与之重叠的更早批次（落 unseq）---"
cmp_make_tree_db "$DB" "$DEVS"
NOW=$(( ($(date +%s) - 3600) * 1000 ))
# seq：[NOW, NOW+ROWS*10)
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 1 "$NOW"
ensure_closed "$DB" 3 25 || warn "$DB seq 批次未全部落盘"
# unseq：整体更早，但与上面区间重叠一半（时间戳 NOW-ROWS*5 ... NOW+ROWS*5）
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 2 "$(( NOW - ROWS * 5 ))"
ensure_closed "$DB" 3 25 || warn "$DB unseq 批次未全部落盘"

u0=$(cmp_unseq_sum "$DB"); cross0=$(cmp_cross_finish "$DB"); ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
log "  起点：TsFile=$ts0 seq=$(cmp_seq_sum "$DB") unseq=$u0 inner finishes=$fin0 cross finishes=$cross0"
for h in "${DN[@]}"; do log "  $h TsFile 清单：$(cmp_tsfile_list "$h" "$DB" | tr '\n' ' ')"; done
[ "$u0" -ge 1 ] && pass "起点存在 unseq TsFile=$u0（具备跨空间合并条件）" || fail "场景无效：起点 unseq=$u0（=0，未产生乱序文件）"
fp0=$(co04_fp "$DB")
fpd0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")

log "--- Phase A（负向）：热开三类合并，${WIN_A}s 内 cross 不应发生（unseq 文件 level=0，被 min_…_level=1 拦住）---"
cmp_compaction_on true true true
deadline=$(( $(date +%s) + WIN_A )); cross_a=0
while (( $(date +%s) < deadline )); do
  sleep 5
  u=$(cmp_unseq_sum "$DB"); c=$(cmp_cross_finish "$DB"); f=$(cmp_inner_finish "$DB")
  log "    等 cross(负向)：unseq=$u(基线$u0) inner finishes=$f(基线$fin0) cross finishes=$c(基线$cross0)"
  [ "$c" -gt "$cross0" ] && { cross_a=1; break; }
done
u_a=$(cmp_unseq_sum "$DB"); c_a=$(cmp_cross_finish "$DB"); f_a=$(cmp_inner_finish "$DB")
[ "${f_a:-0}" -gt "${fin0:-0}" ] && pass "合并机制是活的：inner finishes $fin0 → $f_a（说明不是『合并根本没跑』）" \
  || warn "窗口内 inner finishes 未增加（$fin0 → $f_a），负向结论的说服力下降"
if [ "$cross_a" = 0 ]; then
  pass "负向成立：min_cross_compaction_unseq_file_level=1 时，level=0 的小 unseq 文件(=$u_a 个)未被跨空间合并选中（cross finishes 仍为 $c_a）"
else
  fail "负向不成立：本该被 min_cross_compaction_unseq_file_level 拦住的 level=0 文件仍被跨空间合并（cross finishes $cross0 → $c_a）"
fi
cmp_assert_same "Phase A 期间数据指纹不变" "$fp0" "$(co04_fp "$DB")"

log "--- Phase B（正向）：把 min_cross_compaction_unseq_file_level 改成 0 并重启（**不清理数据**）---"
cluster_stop
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=true,enable_cross_space_compaction=true,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},min_cross_compaction_unseq_file_level=0"
cluster_write_conf
cluster_start
CNT_B=$(row_sum "$(sq "select count(s1) from $DB.**;")")
u_b=$(cmp_unseq_sum "$DB"); ts_b=$(cmp_all_sum "$DB")
log "  重启后：count=$CNT_B TsFile=$ts_b unseq=$u_b（重启前 unseq=$u_a）"
[ "${u_b:-0}" -ge 1 ] && pass "重启后 unseq TsFile 仍在（$u_b 个），Phase B 场景有效" \
  || warn "重启后 unseq=$u_b（可能已被 inner 合并重新落成 seq，正向判定以 cross finishes 增长为准）"
# 基线必须取 **Phase A 的 cross0**（重启前）：重启后跨空间合并可能在几秒内就完成，
# 若拿"重启后读到的值"当基线，就会误判成"没有推进"（第一版踩到：cross 0 → 12 却判 FAIL）。
log "  等跨空间合并（窗口 ${WIN}s）：unseq 应被合并进 seq"
deadline=$(( $(date +%s) + WIN )); ok=0; c=$cross0; u=$u_b
while (( $(date +%s) < deadline )); do
  u=$(cmp_unseq_sum "$DB"); c=$(cmp_cross_finish "$DB")
  log "    等 cross：unseq=$u cross finishes=$c(基线 $cross0，重启前)"
  if [ "$u" = "0" ] && [ "$c" -gt "$cross0" ]; then ok=1; break; fi
  sleep 5
done
if [ "$ok" = 1 ]; then
  pass "跨空间合并已推进：unseq → 0，cross finishes $cross0 → $c（参数置 0 后生效）"
else
  fail "参数置 0 后跨空间合并仍未完成：unseq=$u，cross finishes=$c（基线 $cross0），窗口 ${WIN}s"
fi
cmp_assert_same "Phase B 合并前后 count/sum/min/max" "$fp0" "$(co04_fp "$DB")"
cmp_assert_same "Phase B 合并前后 $DB.d1 全序列（重叠区间取值需正确）" "$fpd0" "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time")"

HIT_OVERLAP=0
for h in "${DN[@]}"; do
  n=$(sshx "$h" "grep -hcE 'has overlapped data|overlapped data' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && { fail "$h 日志出现 $n 条 overlap 相关异常"; HIT_OVERLAP=1; }
done
[ "$HIT_OVERLAP" = 0 ] && pass "合并日志无 overlap 异常"
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"
for h in "${DN[@]}"; do log "  $h 合并日志尾部：$(cmp_log_tail "$h" "$DB" | tr '\n' ' ' | cut -c1-240)"; done

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
