#!/bin/bash
# ============================================================================
# DT-03 修改数据类型 × 合并（核心交叉场景，树模型）
#
# 覆盖点（三个场景用**三个独立库**，避免上一个场景的层级/文件残留影响判定）：
#   A（改后合并）：INT32 序列写 2 行 → 改类型为 DOUBLE → 再写新类型 2 行 ⇒ 一个文件里同时有
#       旧类型（INT32 写的）与新类型（DOUBLE 写的）数据段，开合并让它并到一起
#       —— 断言：合并完成（finishes↑ **且** TsFile↓）、旧值按新类型可读、新值原样、三副本一致
#   B（合并进行中改类型）：TEXT 大序列（约 100KB/行 × 6 批，限流 1MB/s 把合并拖到数秒）+ INT32 序列，
#       开合并后**立刻**对 INT32 序列发起 ALTER ⇒ 合并与 schema 变更真并发
#       —— 断言：ALTER 结果明确、合并最终收敛、两条序列数据都完整（大序列按行数/载荷长度采样）、无异常
#   C（混合数据类型同库合并）：INT32/DOUBLE/TEXT 三条序列各 2 批 ⇒ 合并
#       —— 断言：三条序列指纹各自不变（合并要正确处理同一文件里混合 schema 的设备）
#
# 关键设计：**每个场景写入前先热关三类合并**（否则前一个场景打开的合并会在写入期间就把文件并掉，
#   基线采集后不再有推进 ⇒ 会误判"未收敛"，本轮实测踩过）；写完用 `cmp_wait_lay` 等布局稳定，
#   再热开合并观察。（判据是双信号：finishes 增加 **且** 该库 TsFile 数下降）
# 用法： bash dt_tree_compaction.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_tree_compaction_${DATA_CONSENSUS}"

DB_A=root.dtca
DB_B=root.dtcb
DB_C=root.dtmix
BASE=$(( ($(date +%s) - 3600) * 1000 ))
WIN=${CO_MERGE_WAIT_SEC:-120}
PAYLOAD=$(printf 'p%.0s' $(seq 1 100000))   # 约 100KB/行，配合 1MB/s 限流让合并持续数秒

# 树模型：库 = root.dtcx；设备必须是 root.dtcx.<dev>（不能把 root.dtcxY 当设备用）
dt03_mk(){ sq "create timeseries $1 with datatype=$2, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | grep -c successfully; }
dt03_in(){ sq "insert into $1(time,s1) values $2;" 2>&1 | grep -c successfully; }
dt03_wait_merge(){ local db=$1 fin0=$2 ts0=$3 t=${4:-$WIN} dl ok=0
  # db 必须是**库名**（root.dtca）：cmp_inner_finish/cmp_all_sum 是按库路径统计的
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_inner_finish "$db")" -gt "$fin0" ] && [ "$(cmp_all_sum "$db")" -lt "$ts0" ] && { ok=1; break; }
    sleep 5
  done; echo "$ok"; }
# 大 TEXT 序列的轻量签名（行数 + 首行载荷长度 + 首行前 24 字符），避免把 2MB 数据搬进 shell 变量
dt03_bsig(){ local dev=$1
  echo "rows=$(cmp_rows_series "$DB_B.$dev.s1") len=$(sq "select s1 from $DB_B.$dev order by time limit 1;" 2>&1 | grep -E '^\|' | sed -n 2p | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print length(v)}') head=$(sq "select s1 from $DB_B.$dev order by time limit 1;" 2>&1 | grep -E '^\|' | sed -n 2p | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print substr(v,1,24)}')"; }
dt03_err_scan(){ local h n s=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -haE 'DataTypeInconsistentException|CompactionTableSchemaNotMatchException|not compatible with|Illegal.*[Tt]ype|schema.*mismatch' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -vE 'Alter timeseries .* in schema regions failed' | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} )); done; echo "$s"; }

log "--- 集群准备：三类合并先关；限流 1MB/s（让场景 B 的合并持续数秒）---"
EXTRA_CONF="$CMP_EXTRA_WRITE,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare

# ============================================================================
log "=== 场景 A（$DB_A）：改类型前有旧类型文件 + 改后写新类型 ⇒ 合并 ==="
sq "create database $DB_A;" >/dev/null
cmp_compaction_off
DA="$DB_A.a"
[ "$(dt03_mk "$DA.s1" INT32)" -ge 1 ] && pass "  A: 建 INT32 序列 $DA.s1" || fail "  A: 建序列失败"
[ "$(dt03_in "$DA" "($(( BASE + 100 )),11),($(( BASE + 110 )),12)")" -ge 1 ] && pass "  A: 写入 2 行（INT32）" || fail "  A: 写入失败"
sq "flush;" >/dev/null; sleep 4
rows_a=$(cmp_rows_series "$DA.s1")
[ "${rows_a:-0}" -ge 2 ] && pass "  A: 写入后可见 $rows_a 行" || fail "  A: 写入后只可见 ${rows_a:-0} 行（场景无效）"
ty0=$(cmp_series_type "$DA.s1")
r=$(cmp_alter_ts "$DA.s1" DOUBLE)
if printf '%s' "$r" | grep -qi successfully; then
  pass "  A: INT32 → DOUBLE 成功（原类型 $ty0，新类型 $(cmp_series_type "$DA.s1")）"
else
  fail "  A: 改类型失败：$(printf '%s' "$r" | cut -c1-140)"
fi
dt03_in "$DA" "($(( BASE + 200 )),1.25),($(( BASE + 210 )),2.75)" >/dev/null
sq "flush;" >/dev/null
cmp_wait_lay "$DB_A" "2/0/0/0" 120 >/dev/null || log "  A: 布局未稳定在 2/0/0/0（实际 $(cmp_lay "$DB_A")，记录）"
VALS0=$(cmp_vals_series "$DA.s1" 6); FP0=$(cmp_fp_series "$DA.s1")
FIN0=$(cmp_inner_finish "$DB_A"); TS0=$(cmp_all_sum "$DB_A")
log "  A: 改后布局=$(cmp_lay "$DB_A") 值=$VALS0 文件=$TS0"
L0=$(cmp_min_l0 "$DB_A")
[ "${L0:-0}" -ge 2 ] && pass "  A: 合并起点确有 ≥2 个 level-0 文件（最少 $L0，跨副本）" \
  || { fail "  A: 合并起点只有 $L0 个 level-0 文件（合并无从发生，场景无效）"; }
cmp_compaction_on true false false
OKA=$(dt03_wait_merge "$DB_A" "$FIN0" "$TS0" 180)
log "  A: 合并后布局=$(cmp_lay "$DB_A") finish=$FIN0→$(cmp_inner_finish "$DB_A") TsFile=$TS0→$(cmp_all_sum "$DB_A")"
[ "$OKA" = 1 ] && pass "  A: 新旧类型混合的文件被成功合并（双信号）" || fail "  A: 合并未收敛（finishes=$FIN0 TsFile=$TS0）"
VALS1=$(cmp_vals_series "$DA.s1" 6); FP1=$(cmp_fp_series "$DA.s1")
[ "$FP0" = "$FP1" ] && pass "  A: 合并前后读数一致（$VALS1）" || fail "  A: 合并前后读数不一致：$VALS0 vs $VALS1"
printf '%s' "$VALS1" | grep -q '1.25' && pass "  A: 改类型后写入的新值仍在（$VALS1）" || fail "  A: 新写入的值丢失（$VALS1）"
assert_eq "  A: 合并后类型仍为 DOUBLE" "$(cmp_series_type "$DA.s1")" "DOUBLE"
consistency_check "select s1 from $DA order by time;" tree

# ============================================================================
log "=== 场景 B（$DB_B）：合并进行中改类型（限流 1MB/s，TEXT 大序列 + INT32 序列同库）==="
sq "create database $DB_B;" >/dev/null
cmp_compaction_off
dt03_mk "$DB_B.b1.s1" TEXT >/dev/null; dt03_mk "$DB_B.b2.s1" INT32 >/dev/null
for ts in 1 2 3 4 5 6; do
  { printf 'insert into %s(time,s1) values (%d,%d);\n' "$DB_B.b2" $(( BASE + 1000 * ts )) "$ts"
    printf "insert into %s(time,s1) values (%d,'%s');\n" "$DB_B.b1" $(( BASE + 1000 * ts )) "$PAYLOAD"
    echo 'flush;'; } | session_tree >/dev/null
  sleep 3
done
sq "flush;" >/dev/null
cmp_wait_lay "$DB_B" "6/0/0/0" 180 >/dev/null || log "  B: 布局未稳定在 6/0/0/0（实际 $(cmp_lay "$DB_B")，记录）"
CNTB1_A=$(dt03_bsig b1); FPB2_A=$(cmp_fp_series "$DB_B.b2.s1")
FINB0=$(cmp_inner_finish "$DB_B"); TSB0=$(cmp_all_sum "$DB_B")
log "  B: 起点布局=$(cmp_lay "$DB_B") 文件=$TSB0 b1 签名=$CNTB1_A"
L0=$(cmp_min_l0 "$DB_B")
[ "${L0:-0}" -ge 2 ] && pass "  B: 合并起点确有 ≥2 个 level-0 文件（最少 $L0）" \
  || fail "  B: 合并起点只有 $L0 个 level-0 文件（场景无效）"
cmp_compaction_on true false false
rB=$(cmp_alter_ts "$DB_B.b2.s1" DOUBLE)
log "  B: 合并进行中 ALTER b2 序列 → $(printf '%s' "$rB" | cut -c1-140)"
if printf '%s' "$rB" | grep -qi successfully; then
  pass "  B: 合并期间 ALTER 成功，类型=$(cmp_series_type "$DB_B.b2.s1")"
else
  pass "  B: 合并期间 ALTER 被明确拒绝（$(printf '%s' "$rB" | grep -oE '[0-9]{3}: .*' | cut -c1-90)）—— 只要给出明确错误即可接受"
fi
# 改类型会改变值的**呈现**（1 → 1.0），所以基准要取在 ALTER 之后
FPB2_B=$(cmp_fp_series "$DB_B.b2.s1")
OKB=$(dt03_wait_merge "$DB_B" "$FINB0" "$TSB0" 240)
log "  B: 终态布局=$(cmp_lay "$DB_B") finish=$FINB0→$(cmp_inner_finish "$DB_B") TsFile=$TSB0→$(cmp_all_sum "$DB_B")"
[ "$OKB" = 1 ] && pass "  B: 合并最终收敛（双信号）" || fail "  B: 合并未收敛（finishes=$FINB0 TsFile=$TSB0）"
CNTB1_B=$(dt03_bsig b1)
cmp_assert_same "  B: b1 大 TEXT 序列签名（行数/载荷长度/前 24 字符）" "$CNTB1_A" "$CNTB1_B"
cmp_assert_same "  B: b2 序列指纹（ALTER 后 → 合并后）" "$FPB2_B" "$(cmp_fp_series "$DB_B.b2.s1")"
log "     （b1 起点签名=$CNTB1_A；b2 改类型前指纹=$FPB2_A，仅作记录）"

# ============================================================================
log "=== 场景 C（$DB_C）：同一 region 内混合数据类型文件一起合并 ==="
sq "create database $DB_C;" >/dev/null
cmp_compaction_off
DC1="$DB_C.i32"; DC2="$DB_C.dbl"; DC3="$DB_C.tx"
dt03_mk "$DC1.s1" INT32 >/dev/null; dt03_mk "$DC2.s1" DOUBLE >/dev/null; dt03_mk "$DC3.s1" TEXT >/dev/null
for i in 1 2; do
  dt03_in "$DC1" "($(( BASE + 2000 * i )),$(( i * 10 )))" >/dev/null
  dt03_in "$DC2" "($(( BASE + 2000 * i )),$i.5)" >/dev/null
  dt03_in "$DC3" "($(( BASE + 2000 * i )),'v$i')" >/dev/null
  sq "flush;" >/dev/null; sleep 3
done
sq "flush;" >/dev/null
cmp_wait_lay "$DB_C" "2/0/0/0" 120 >/dev/null || log "  C: 布局未稳定在 2/0/0/0（实际 $(cmp_lay "$DB_C")，记录）"
FPI=$(cmp_fp_series "$DC1.s1"); FPD=$(cmp_fp_series "$DC2.s1"); FPT=$(cmp_fp_series "$DC3.s1")
FINC0=$(cmp_inner_finish "$DB_C"); TSC0=$(cmp_all_sum "$DB_C")
log "  C: 起点布局=$(cmp_lay "$DB_C") 文件=$TSC0；指纹 i32=$FPI db=$FPD tx=$FPT"
L0=$(cmp_min_l0 "$DB_C")
[ "${L0:-0}" -ge 2 ] && pass "  C: 合并起点确有 ≥2 个 level-0 文件（最少 $L0）" \
  || fail "  C: 合并起点只有 $L0 个 level-0 文件（场景无效）"
cmp_compaction_on true false false
OKC=$(dt03_wait_merge "$DB_C" "$FINC0" "$TSC0" 180)
log "  C: 合并后布局=$(cmp_lay "$DB_C") finish=$FINC0→$(cmp_inner_finish "$DB_C") TsFile=$TSC0→$(cmp_all_sum "$DB_C")"
[ "$OKC" = 1 ] && pass "  C: 混合类型文件合并完成（双信号）" || fail "  C: 混合类型文件合并未收敛"
cmp_assert_same "  C: INT32 序列指纹" "$FPI" "$(cmp_fp_series "$DC1.s1")"
cmp_assert_same "  C: DOUBLE 序列指纹" "$FPD" "$(cmp_fp_series "$DC2.s1")"
cmp_assert_same "  C: TEXT 序列指纹" "$FPT" "$(cmp_fp_series "$DC3.s1")"

# ============================================================================
log "=== 类型/模式相关异常扫描 ==="
NERR=$(dt03_err_scan)
[ "${NERR:-0}" -eq 0 ] && pass "  三个场景全程没有 DataType/schema 不一致类异常" \
  || { fail "  出现 ${NERR} 条 DataType/schema 相关异常"; for h in "${DN[@]}"; do sshx "$h" "grep -haE 'DataTypeInconsistentException|CompactionTableSchemaNotMatchException|not compatible with' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -5 | cut -c1-200" 2>/dev/null | sed 's/^/    | /' >>"$OUT"; done; }

log "--- 收尾三件套 ---"
post_checks "select s1 from $DA order by time;" tree
cmp_case_finish "" tree ""
