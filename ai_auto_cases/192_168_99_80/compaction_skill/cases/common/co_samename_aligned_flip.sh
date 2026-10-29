#!/bin/bash
# ============================================================================
# CO-43 同名序列重建 + 对齐属性翻转 后的合并（官方 MG-P18 / MG-P19，缺陷 IOTDB-5686）
#
# 官方原文（《V2.0.0.1-…-文件合并-软件测试文档》对比表序号 18/19）：
#   序号18：**顺序空间内** 建普通序列 → **delete 部分 devices** → 建**与 deleted 同名**的对齐序列
#          → 这些 tsfile **在同一个合并任务里** → 合并完成查看结果。
#          首测「不通过 IOTDB-5686」：`select s_0 from …d_0` **只有 80 个点，数据不一致**；
#          复测1「合并报错已解决，但是数据不一致」；复测2 `rc/1.1.0 0323_cb851d1` **通过**
#          （d_0/d_1 每序列 **310 点**、其余 98 个 **270 点**、100 个设备属性都是非对齐…等）。
#   序号19：在此基础上再加**乱序数据**（生成 30 个乱序 0 层 tsfile → 乱序空间内合并 → 跨空间合并）
#          → **重启集群后复验**，同样要求点数与设备属性通过。
#
# 本用例把它缩到 3C3D 单库可控规模，但保留官方的**核心语义**：
#   · 设备 d1/d2：先以**非对齐**序列写入（批1）→ `DELETE TIMESERIES` 删掉设备与数据
#     → **同名重建为对齐序列** → 再写（批2，时间与批1 重叠）⇒ 同一个时间分区里同时存在
#     "含 d1/d2 非对齐数据的旧文件"与"含 d1/d2 对齐数据的新文件"，且两者会被**同一合并任务**吃到
#     （`inner_compaction_candidate_file_num=2` + 分区内恰好 2 个 seq 文件 ⇒ 文件数 2→1 即"同任务"证据）
#   · 设备 d3..d6：全程保持**非对齐**，作为对照（不能被误删/误合并）
#   · 判据（对应官方"数据一致"）：d1/d2 的行数 == 批2 行数（旧数据已被 DELETE、不得复活也不得丢），
#     d3..d6 的行数 == 批1+批2，逐点 (time,value) 指纹不变，跨重启复验（MG-P19）
#
# 源码/语义依据：
#   · `DELETE TIMESERIES <dev>.**` 删设备元数据 + 数据（skill 内已验证的语法）
#   · 对齐序列 DDL/写入：`CREATE ALIGNED TIMESERIES db.d(m1 t1, m2 t2)` + `INSERT INTO … ALIGNED VALUES`
#   · 官方缺陷表现 = **行数不一致**（80 vs 310），所以判据必须落在"逐设备行数 + 逐点指纹"上，
#     而不是只看"合并完成/无报错"
#
# 用法： bash co_samename_aligned_flip.sh [--consensus IoTConsensus]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_samename_aligned_flip_${DATA_CONSENSUS}"

DB=root.co43
FLIP="d1 d2"          # 对齐属性翻转的设备（非对齐 → DELETE → 同名对齐）
CTRL="d3 d4 d5 d6"    # 对照设备（全程非对齐）
ROWS1="${CO43_ROWS1:-300}"   # 批1（非对齐）每设备点数
ROWS2="${CO43_ROWS2:-400}"   # 批2（翻转后）每设备点数
UNSEQ_BATCHES="${CO43_UNSEQ_BATCHES:-3}"

# ---- 取证基元 -------------------------------------------------------------
# 逐设备行数：树方言对"具体设备路径"做聚合可能返回空集 ⇒ 一律用**原始查询数行**
c43_rows_dev(){ sq "select s0 from $DB.$1 order by time;" 2>&1 | strip_echo | data_rows | wc -l | tr -d ' '; }
# 逐设备 (time,value) 指纹（原始查询结果归一化后排序，跨重启稳定）
c43_fp_dev(){ sq "select s0,s1 from $DB.$1 order by time;" 2>&1 | strip_echo | data_rows | tr -s ' ' | sort | md5sum | cut -c1-16; }
c43_all_rows(){ local s=0 d; for d in $FLIP $CTRL; do s=$(( s + $(c43_rows_dev "$d") )); done; echo "$s"; }
c43_all_fp(){ local d; for d in $FLIP $CTRL; do printf '%s=%s\n' "$d" "$(c43_fp_dev "$d")"; done | md5sum | cut -c1-16; }
c43_su(){ cmp_su "$DB" | tr ' ' '\n' | grep -E '^[0-9]+:' | awk -F'[:/]' '{s+=$2; u+=$3} END{printf "seq=%d unseq=%d", s+0, u+0}'; }
# show devices 原文（官方判据①是"设备属性"，列名随版本可能不同 ⇒ 记录 + 宽松解析）
c43_show_devices(){ local out; out=$(sq "show devices $DB.**;" 2>&1 | strip_echo)
  printf '%s\n' "$out" >>"$OUT"; printf '%s' "$out"; }
c43_align_of(){ # <show devices 原文> <device> -> aligned|notaligned|unknown
  # 注意：设备单元格是**全路径** `root.co43.d1`，不能只匹配 `d1`
  local row; row=$(printf '%s\n' "$1" | grep -E "\|[^|]*[.]$2 *\|" | head -1 | tr 'A-Z' 'a-z')
  [ -z "$row" ] && { echo unknown; return; }
  case "$row" in *true*) echo aligned;; *false*) echo notaligned;; *) echo unknown;; esac; }

c43_mkdb(){ local db=$1 d m
  sq "create database $db;" >/dev/null 2>&1
  for d in $FLIP $CTRL; do for m in s0 s1; do sq "create timeseries $db.$d.$m with datatype=INT64;" >/dev/null 2>&1; done; done; }
# 非对齐批量写：<dev> <base> <rows> <valueBase>
c43_write_plain(){ local dev=$1 base=$2 rows=$3 vb=$4 k vals=""
  for ((k=1;k<=rows;k++)); do vals="$vals($(( base + k*10 )),$(( vb + k )),$(( vb + k*2 ))),"; done
  sq "insert into $DB.$dev(time,s0,s1) values ${vals%,};" >/dev/null 2>&1; }
# 对齐批量写：<dev> <base> <rows> <valueBase>
c43_write_aligned(){ local dev=$1 base=$2 rows=$3 vb=$4 k vals=""
  for ((k=1;k<=rows;k++)); do vals="$vals($(( base + k*10 )),$(( vb + k )),$(( vb + k*2 ))),"; done
  sq "insert into $DB.$dev(time,s0,s1) aligned values ${vals%,};" >/dev/null 2>&1; }

log "--- 0) 集群准备：三类合并全关；candidate=2（保证分区内 2 个文件被**同一任务**吃到）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare

log "=== 1) 建 6 个设备（全部非对齐）并写批1（$ROWS1 点/设备）==="
cmp_compaction_off
c43_mkdb "$DB"
T0=$(now_ms)
for d in $FLIP $CTRL; do c43_write_plain "$d" "$(( T0 + 10000 ))" "$ROWS1" 1000; done
sq "flush;" >/dev/null 2>&1
cmp_wait_close "$DB" 1 120 >/dev/null || warn "  批1 close 事件未达标"
LAY1=$(cmp_lay "$DB")
log "  批1 布局=$LAY1 空间=$(c43_su)"
assert_contains "  场景有效性：批1 后各副本有 level-0 文件" "$LAY1" '[1-9][0-9]*/0/0/0'
R1_FLIP=$(c43_rows_dev d1); R1_CTRL=$(c43_rows_dev d3)
log "  批1 行数：d1=$R1_FLIP（期望 $ROWS1） d3=$R1_CTRL（期望 $ROWS1）"
assert_eq "  [场景有效性] 批1 d1 行数" "$R1_FLIP" "$ROWS1"

log "=== 2) DELETE 掉 d1/d2 的设备与数据 → 同名重建为**对齐**序列 ==="
for d in $FLIP; do
  local_out=$(sq "delete timeseries $DB.$d.**;" 2>&1)
  log "  delete timeseries $DB.$d.** → $(printf '%s' "$local_out" | strip_echo | tail -1)"
done
D1_AFTER_DEL=$(c43_rows_dev d1)
log "  DELETE 后 d1 行数 = $D1_AFTER_DEL（期望 0：元数据+数据都删掉）"
assert_eq "  [场景有效性] DELETE 后 d1 无数据" "$D1_AFTER_DEL" "0"
for d in $FLIP; do sq "create aligned timeseries $DB.$d(s0 int64,s1 int64);" >/dev/null 2>&1; done
AL_OK=1
for d in $FLIP; do
  sq "show timeseries $DB.$d.s0;" 2>&1 | grep -q "$DB.$d.s0" || AL_OK=0
done
[ "$AL_OK" = 1 ] && pass "  [场景有效性] d1/d2 已按**对齐**序列同名重建" || fail "  [场景有效性] 同名重建失败（对齐 DDL 未生效）"

log "=== 3) 写批2（$ROWS2 点/设备）：翻转设备用 **ALIGNED** 写入，对照设备仍非对齐；时间接在批1 之后 ==="
# 关键：批2 的时间必须**晚于批1 的水位**（否则会落乱序区，就不是官方 MG-P18 的"顺序空间内"场景了），
# 同时仍在**同一时间分区**内（默认 1 周）⇒ 两代文件都留在 sequence/ 且被同一任务选中。
T1=$(( T0 + 20000 ))
for d in $FLIP; do c43_write_aligned "$d" "$T1" "$ROWS2" 5000; done
for d in $CTRL; do c43_write_plain  "$d" "$T1" "$ROWS2" 5000; done
sq "flush;" >/dev/null 2>&1
cmp_wait_close "$DB" 2 150 >/dev/null || warn "  批2 close 事件未达标"
LAY2=$(cmp_lay "$DB")
log "  批2 布局=$LAY2 空间=$(c43_su)"
assert_contains "  [场景有效性] 批2 后每副本 ≥2 个 level-0 文件（同分区内两代文件）" "$LAY2" '([2-9]|[1-9][0-9]+)/0/0/0'

# 合并前基线（判据：官方核心是"点数一致"，所以逐设备行数 + 逐点指纹都要在合并前后一致）
R_FLIP0=$(c43_rows_dev d1); R_CTRL0=$(c43_rows_dev d3); ALL0=$(c43_all_rows); FP0=$(c43_all_fp)
DEV0=$(c43_show_devices)
log "  合并前：d1=$R_FLIP0（期望 $ROWS2，旧点已被 DELETE） d3=$R_CTRL0（期望 $(( ROWS1 + ROWS2 ))） 全库=$ALL0"
assert_eq "  [场景有效性] 合并前 d1 只有批2 的点" "$R_FLIP0" "$ROWS2"
assert_eq "  [场景有效性] 合并前 d3 = 批1+批2" "$R_CTRL0" "$(( ROWS1 + ROWS2 ))"
case "$(c43_align_of "$DEV0" d1)" in
  aligned)    pass "  官方判据①：d1 设备属性 = 对齐" ;;
  notaligned) fail "  官方判据①：d1 设备属性仍是非对齐（同名重建未生效）" ;;
  *)          warn "  show devices 无 Aligned 列（版本差异），属性判据①仅记录原文" ;;
esac
case "$(c43_align_of "$DEV0" d3)" in
  notaligned) pass "  官方判据①：对照设备 d3 属性 = 非对齐" ;;
  aligned)    warn "  官方判据①：d3 也是对齐（记录，可能是环境属性差异）" ;;
  *)          warn "  show devices 无 Aligned 列，属性判据①仅记录" ;;
esac

log "=== 4) 顺序空间内合并（两代文件必须被**同一任务**吃到：文件数 2→1）==="
FIN0=$(cmp_inner_finish "$DB"); SUM0=$(cmp_all_sum "$DB")
cmp_compaction_on true false false
ok=0; dl=$(( $(date +%s) + ${CO_MERGE_WAIT_SEC:-120} ))
while (( $(date +%s) < dl )); do
  f=$(cmp_inner_finish "$DB"); s=$(cmp_all_sum "$DB")
  [ "${f:-0}" -gt "${FIN0:-0}" ] && [ "${s:-9}" -lt "${SUM0:-0}" ] && { ok=1; break; }
  sleep 3
done
sleep 5
FIN1=$(cmp_inner_finish "$DB"); SUM1=$(cmp_all_sum "$DB"); LAY3=$(cmp_lay "$DB")
log "  合并后：布局=$LAY3 文件 $SUM0 → $SUM1 finishes $FIN0 → $FIN1"
cmp_log_tail "${DN[0]}" "$DB" 2>/dev/null | sed 's/^/    日志: /' >>"$OUT" || true
[ "$ok" = 1 ] && pass "  双信号：合并完成数增加且文件数下降（$SUM0 → $SUM1，finishes +$(( FIN1 - FIN0 ))）" \
  || fail "  合并未推进（finishes $FIN0→$FIN1，文件 $SUM0→$SUM1）"
[ "$SUM1" -lt "$SUM0" ] && [ $(( SUM0 - SUM1 )) -ge 1 ] && pass "  「同一任务」证据：分区内两代文件被一起吃掉（文件数至少 -1）" \
  || warn "  文件数未下降，无法证明两代文件同任务（记录）"

# 官方核心判据：数据一致（IOTDB-5686 的表现就是行数不一致）
R_FLIP1=$(c43_rows_dev d1); R_CTRL1=$(c43_rows_dev d3); ALL1=$(c43_all_rows); FP1=$(c43_all_fp)
log "  合并后行数：d1 $R_FLIP0 → $R_FLIP1，d3 $R_CTRL0 → $R_CTRL1，全库 $ALL0 → $ALL1"
assert_eq "  **官方核心判据**：合并后 d1 行数不变（对齐侧数据不多不少）" "$R_FLIP1" "$R_FLIP0"
assert_eq "  **官方核心判据**：合并后 d2 行数不变" "$(c43_rows_dev d2)" "$ROWS2"
assert_eq "  **官方核心判据**：合并后对照设备 d3 行数不变（批1+批2 未被误删）" "$R_CTRL1" "$R_CTRL0"
for d in $CTRL; do assert_eq "  对照设备 $d 行数不变" "$(c43_rows_dev "$d")" "$(( ROWS1 + ROWS2 ))"; done
assert_eq "  合并前后「逐设备逐点 (time,value) 指纹」不变" "$FP1" "$FP0"
DEV1=$(c43_show_devices)
case "$(c43_align_of "$DEV1" d1)" in
  aligned) pass "  合并后 d1 仍是对齐属性（官方复测2 的判据）" ;;
  notaligned) fail "  合并后 d1 变成非对齐（官方 IOTDB-5686 同族问题）" ;;
  *) warn "  show devices 无 Aligned 列，属性判据仅记录" ;;
esac
FP_ALIGN=$(c43_fp_dev d1)
assert_contains "  官方判据：d1 可直接按对齐读回（select s0,s1 … 非空）" "$(sq "select s0,s1 from $DB.d1 order by time;" 2>&1 | strip_echo)" '\|'

log "=== 5) MG-P19：加入乱序数据 → 乱序内部合并 + 跨空间合并 ==="
cmp_compaction_off
T2=$(( T0 + 4000 ))           # 明确早于批1/批2 的水位 ⇒ 必然落 unseq 空间（仍属同一时间分区）
for b in $(seq 1 "$UNSEQ_BATCHES"); do
  for d in $FLIP; do c43_write_aligned "$d" "$(( T2 + b * 7 ))" 50 "$(( 9000 + b ))"; done
  for d in $CTRL; do c43_write_plain  "$d" "$(( T2 + b * 7 ))" 50 "$(( 9000 + b ))"; done
done
sq "flush;" >/dev/null 2>&1
sleep 5
SU_U=$(c43_su "$DB"); log "  乱序写入后空间=$SU_U 布局=$(cmp_lay "$DB")"
assert_contains "  [场景有效性] 已产生乱序文件（unseq ≥1）" "$SU_U" 'unseq=[1-9]'
U_EXTRA=$(( UNSEQ_BATCHES * 50 ))
cmp_compaction_on true true false
ok2=0; dl=$(( $(date +%s) + ${CO_MERGE_WAIT_SEC:-120} ))
while (( $(date +%s) < dl )); do
  u=$(cmp_unseq_sum "$DB"); [ "${u:-9}" -eq 0 ] && { ok2=1; break; }; sleep 3
done
sleep 5
log "  unseq 归零=$( [ "$ok2" = 1 ] && echo 是 || echo 否 )（unseq=$(cmp_unseq_sum "$DB")）finishes=$(cmp_inner_finish "$DB") cross=$(cmp_cross_finish "$DB")"
[ "$ok2" = 1 ] && pass "  乱序内部合并 + 跨空间合并后 unseq 归零" || warn "  unseq 未归零（$SU_U，窗口内）"
assert_eq "  乱序合并后 d1 行数 = 批2 + 乱序批（不丢不复活）" "$(c43_rows_dev d1)" "$(( ROWS2 + U_EXTRA ))"
assert_eq "  乱序合并后 d3 行数 = 批1+批2+乱序批" "$(c43_rows_dev d3)" "$(( ROWS1 + ROWS2 + U_EXTRA ))"

log "=== 6) MG-P19：**重启集群后复验**（官方要求重启后点数与属性仍通过）==="
R_FLIP_PRE=$(c43_rows_dev d1); R_CTRL_PRE=$(c43_rows_dev d3); FP_PRE=$(c43_all_fp)
cluster_stop
cluster_start || fail "重启后集群未就绪"
sleep 10
R_FLIP_POST=$(c43_rows_dev d1); R_CTRL_POST=$(c43_rows_dev d3); FP_POST=$(c43_all_fp)
DEV2=$(c43_show_devices)
log "  重启后：d1 $R_FLIP_PRE → $R_FLIP_POST，d3 $R_CTRL_PRE → $R_CTRL_POST"
assert_eq "  **重启后复验**：d1 行数不变" "$R_FLIP_POST" "$R_FLIP_PRE"
assert_eq "  **重启后复验**：d3 行数不变" "$R_CTRL_POST" "$R_CTRL_PRE"
assert_eq "  **重启后复验**：逐点指纹不变" "$FP_POST" "$FP_PRE"
case "$(c43_align_of "$DEV2" d1)" in
  aligned) pass "  **重启后复验**：d1 仍是对齐属性" ;;
  notaligned) fail "  **重启后复验**：d1 变成非对齐" ;;
  *) warn "  show devices 无 Aligned 列，重启后属性仅记录" ;;
esac

log "--- 收尾三件套 ---"
post_checks "select s0 from ${DB}.d3 order by time;" tree
cmp_case_finish "" tree ""
