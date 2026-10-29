#!/bin/bash
# ============================================================================
# DT-06 修改数据类型（**表模型**）× 合并（顺序空间 + 跨空间 + 并发 DROP TABLE）
#
# 覆盖点：
#   A：改列类型前有 TsFile（旧类型）+ 改后写新类型 ⇒ 顺序空间内部合并 ⇒ 值/类型正确、无 schema 异常
#   B：改列类型后制造**与 seq 时间范围重叠**的乱序数据 ⇒ 跨空间合并 ⇒ unseq 归零、值正确
#   C：并发 `DROP TABLE` ∥ `ALTER COLUMN ... SET DATA TYPE` ⇒ 必须给出明确结果（550 表不存在或改成功），
#      不得出现"表已删但元数据残留/数据复活"等损坏
#
# 关键设计（与 DT-03 一致）：每个场景**写入前先热关三类合并**（否则上一场景开着的合并会在写入期间
#   把文件并掉，基线之后不再推进 ⇒ 误判"未收敛"，DT-03 本轮实测踩过）。
#   表模型坑：`SELECT` 只返回**投影列**（`select v from t` 每行只有 1 列），取值必须按表头定位列号。
# 用法： bash dt_table_compaction.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_table_compaction_${DATA_CONSENSUS}"

DB=dtcmix
BASE=$(( ($(date +%s) - 3600) * 1000 ))
WIN=${CO_MERGE_WAIT_SEC:-120}

# 取值/类型/行数：表模型一律按列名解析（见 lib/cmp.sh 的说明）
dt06_vals(){ cmp_tbl_col_vals "select $1 from $DB.$2 order by time;" "$1"; }
dt06_rows(){ cmp_tbl_rows "select time from $DB.$1 order by time;"; }
dt06_type(){ cmp_tbl_coltype "$DB.$1" "$2"; }
dt06_wait_merge(){ local db=$1 fin0=$2 ts0=$3 t=${4:-$WIN} dl ok=0; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_inner_finish "$db")" -gt "$fin0" ] && [ "$(cmp_all_sum "$db")" -lt "$ts0" ] && { ok=1; break; }
    sleep 5
  done; echo "$ok"; }
dt06_wait_unseq(){ local db=$1 t=${2:-$WIN} dl ok=0; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do [ "$(cmp_unseq_sum "$db")" = "0" ] && { ok=1; break; }; sleep 5; done; echo "$ok"; }

log "--- 集群准备：三类合并先关；min_cross_unseq_level=0 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE,min_cross_compaction_unseq_file_level=0" cmp_cluster_prepare

log "=== A) 表模型改列类型 + 顺序空间内部合并 ==="
sqt "create database $DB;" >/dev/null 2>&1
sqt "create table $DB.ta (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD);" >/dev/null
cmp_compaction_off
[ "$(sqt "insert into $DB.ta (time, dev, v) values ($(( BASE + 100 )),'d1',11),($(( BASE + 110 )),'d1',12);" 2>&1 | grep -c successfully)" -ge 1 ] \
  && pass "  A: 写入 2 行（INT32）" || fail "  A: 写入失败"
sqt "flush;" >/dev/null
r=$(cmp_alter_col "alter table $DB.ta alter column v set data type DOUBLE;")
printf '%s' "$r" | grep -qi successfully && pass "  A: INT32 → DOUBLE 成功" || fail "  A: 改列类型失败：$(printf '%s' "$r" | cut -c1-130)"
sqt "insert into $DB.ta (time, dev, v) values ($(( BASE + 200 )),'d1',1.25),($(( BASE + 210 )),'d1',2.5);" >/dev/null
sqt "flush;" >/dev/null
cmp_wait_lay "$DB" "2/0/0/0" 90 >/dev/null || log "  A: 布局未稳定在 2/0/0/0（实际 $(cmp_lay "$DB")，记录）"
V0=$(dt06_vals v ta); FINA=$(cmp_inner_finish "$DB"); TSA=$(cmp_all_sum "$DB")
log "  A: 改后布局=$(cmp_lay "$DB") 值=$V0 文件=$TSA"
L0=$(cmp_min_l0 "$DB")
[ "${L0:-0}" -ge 2 ] && pass "  A: 合并起点确有 ≥2 个 level-0 文件（最少 $L0，跨副本）" \
  || fail "  A: 合并起点只有 $L0 个 level-0 文件（合并无从发生，场景无效）"
cmp_compaction_on true false false
OKA=$(dt06_wait_merge "$DB" "$FINA" "$TSA" 180)
log "  A: 合并后布局=$(cmp_lay "$DB") finish=$FINA→$(cmp_inner_finish "$DB") TsFile=$TSA→$(cmp_all_sum "$DB")"
[ "$OKA" = 1 ] && pass "  A: 改类型前后的文件被成功合并（双信号）" || fail "  A: 合并未收敛"
V1=$(dt06_vals v ta)
[ "$V0" = "$V1" ] && pass "  A: 合并前后值一致（$V1）" || fail "  A: 值发生变化：$V0 → $V1"
printf '%s' "$V1" | grep -q '1.25' && pass "  A: 改类型后写入的值仍在" || fail "  A: 新值丢失（$V1）"
assert_eq "  A: 合并后 desc 类型仍为 DOUBLE" "$(dt06_type ta v)" "DOUBLE"

log "=== B) 改列类型 + 跨空间合并（乱序数据与 seq 时间范围重叠）==="
cmp_compaction_off
sqt "create table $DB.tb (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD);" >/dev/null
sqt "insert into $DB.tb (time, dev, v) values ($(( BASE + 500000 )),'d1',1),($(( BASE + 500010 )),'d1',2);" >/dev/null
sqt "flush;" >/dev/null; sleep 4
r=$(cmp_alter_col "alter table $DB.tb alter column v set data type DOUBLE;")
printf '%s' "$r" | grep -qi successfully && pass "  B: 改列类型成功（INT32 → DOUBLE）" || fail "  B: 改列类型失败"
# 落在 seq 时间范围**之内**的乱序点（500003/500005... 早于 seq 的最大时间 500010）⇒ 进 unseq 且与 seq 重叠
for i in 1 2; do
  sqt "insert into $DB.tb (time, dev, v) values ($(( BASE + 500000 + i * 2 + 1 )),'d1',$i.5),($(( BASE + 500000 + i * 3 + 1 )),'d1',$(( i + 3 )).5);" >/dev/null
  sqt "flush;" >/dev/null; sleep 4
done
sleep 3
log "  B: 起点 seq/unseq=$(cmp_su "$DB") 布局=$(cmp_lay "$DB")"
UB0=$(cmp_unseq_sum "$DB"); VB0=$(dt06_vals v tb); XB0=$(cmp_cross_finish "$DB")
[ "${UB0:-0}" -ge 1 ] && pass "  B: 已构造出乱序文件（unseq=$UB0）" || fail "  B: 没有产生乱序文件（unseq=0，场景无效）"
cmp_compaction_on false false true
OKB=$(dt06_wait_unseq "$DB" 180)
VB1=$(dt06_vals v tb); XB1=$(cmp_cross_finish "$DB")
log "  B: 终态 seq/unseq=$(cmp_su "$DB") unseq=$UB0→$(cmp_unseq_sum "$DB") cross finishes=$XB0→$XB1 值=$VB1"
[ "$OKB" = 1 ] && pass "  B: 改列类型后跨空间合并完成（unseq 归零）" || fail "  B: unseq 未归零（$(cmp_unseq_sum "$DB")）"
[ "$XB1" -gt "$XB0" ] && pass "  B: 有真实 CrossSpaceCompaction 任务完成（$XB0→$XB1）" \
  || log "  B: 未见 CrossSpace 任务完成计数增加（可能是整文件插入路径，记录）"
[ "${VB0:-x}" = "${VB1:-y}" ] && pass "  B: 跨空间合并前后值一致（$VB1）" || fail "  B: 值变化 $VB0 → $VB1"
assert_eq "  B: 合并后 desc 类型仍为 DOUBLE" "$(dt06_type tb v)" "DOUBLE"

log "=== C) 并发 DROP TABLE ∥ ALTER COLUMN ==="
sqt "create table $DB.tc1 (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD);" >/dev/null
sqt "insert into $DB.tc1 (time, dev, v) values ($(( BASE + 300 )),'d1',1);" >/dev/null
sqt "flush;" >/dev/null; sleep 4
( sqt "drop table $DB.tc1;" >/tmp/dt06_drop.out 2>&1 ) & dp=$!
( cmp_alter_col "alter table $DB.tc1 alter column v set data type DOUBLE;" >/tmp/dt06_alt.out 2>&1 ) & ap=$!
wait $dp $ap
ares=$(cat /tmp/dt06_alt.out | tr '\n' ' ' | cut -c1-140)
dres=$(cat /tmp/dt06_drop.out | tr '\n' ' ' | cut -c1-100)
log "  C: ALTER→$ares ；DROP→$dres"
if printf '%s' "$ares" | grep -qi successfully; then
  pass "  C: ALTER 先成功（随后删除表）——顺序合规"
elif printf '%s' "$ares" | grep -qiE '550|not exist|701'; then
  pass "  C: 表已被并发删除 ⇒ ALTER 给出明确错误（$(printf '%s' "$ares" | grep -oE '[0-9]{3}: .*' | cut -c1-80)）"
else
  warn "  C: ALTER 结果不明确：$ares"
fi
q=$(sqt "select v from $DB.tc1 order by time;" 2>&1 | tr '\n' ' ' | cut -c1-120)
printf '%s' "$q" | grep -qiE '550|not exist' && pass "  C: 删除后查询表明确报不存在（无残留元数据/数据复活）" \
  || warn "  C: 删除后查询响应：$q"
# 表已删 ⇒ 元数据里不应再出现该表
tl=$(sqt "show tables from $DB;" 2>&1 | grep -c 'tc1')
[ "${tl:-0}" -eq 0 ] && pass "  C: show tables 里不再有 tc1" || fail "  C: 表删除后 show tables 仍列出 tc1"

log "=== schema/类型异常扫描 ==="
NERR=0
for h in "${DN[@]}"; do
  n=$(sshx "$h" "grep -haE 'DataTypeInconsistentException|CompactionTableSchemaNotMatchException|not compatible with' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -vE 'Alter .* in schema regions failed|is not compatible with the existing one' | wc -l" 2>/dev/null | tr -dc '0-9')
  NERR=$(( NERR + ${n:-0} ))
done
[ "$NERR" -eq 0 ] && pass "  全程没有表模型 schema 不一致类异常" || fail "  出现 $NERR 条 schema 相关异常"

log "--- 收尾三件套（本用例故意触发过负向 DDL，预期错误列入 benign）---"
export CMP_LOG_BENIGN_EXTRA='not compatible with the existing one|Can only alter datatype of FIELD|Alter (table|column).*(failed)|Status code: (507|508|550|701)|Column .* does not exist|Table .* does not exist|does not exist'
post_checks "select v from $DB.ta order by time;" table
cmp_case_finish "" table ""
