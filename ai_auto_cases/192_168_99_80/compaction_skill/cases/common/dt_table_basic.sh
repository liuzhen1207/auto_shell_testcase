#!/bin/bash
# ============================================================================
# DT-05 修改数据类型（**表模型**）基础功能 + FIELD-only 限制 + 兼容性
#
# 需求来源：手册「表模型 1.4/2.4 修改表」：`ALTER TABLE ... ALTER COLUMN col SET DATA TYPE new_type`
#   · V2.0.8 起支持，**只支持 Category=FIELD 的字段**（TAG 不支持）；
#   · 变更后的类型需要与原类型兼容（同一张兼容表）；
#   · 变更过程中若该时间序列被并发删除，会报错提示。
# 判据：正向转换成功 + `desc` 显示新类型 + 旧值按新类型可读 + 负向（TAG/时间列/不兼容）报 701 + 三副本一致。
# 用法： bash dt_table_basic.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_table_basic_${DATA_CONSENSUS}"

DB=dtb
BASE=$(( ($(date +%s) - 3600) * 1000 ))

# 表模型某列的当前类型（`desc` 第 2 列）
dt05_coltype(){ cmp_tbl_coltype "$DB.$1" "$2"; }
# 表模型取值/数行：用 lib 的**按列名**取值（表模型 SELECT 只返回投影列，硬编码列号会取到空串——踩过）
dt05_vals(){ cmp_tbl_col_vals "select $1 from $DB.t1 order by time;" "$1"; }
dt05_rows(){ cmp_tbl_rows "select time from $DB.t1 order by time;"; }
dt05_all_same(){ local q=$1 h a ok=1 base
  base=$(sqt_node "${DN[0]}" "$q" 2>/dev/null | grep -E '^\|' | tr -d ' ')
  for h in "${DN[@]}"; do
    a=$(sqt_node "$h" "$q" 2>/dev/null | grep -E '^\|' | tr -d ' ')
    [ "$a" = "$base" ] || ok=0
  done; echo "$ok"; }

log "--- 集群准备：三类合并先关 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- ① 建表（TAG dev + FIELD i32/f32/str/dbl）+ 写数据 ---"
sqt "create database $DB;" >/dev/null 2>&1
sqt "create table $DB.t1 (time TIMESTAMP TIME, dev STRING TAG, i32 INT32 FIELD, f32 FLOAT FIELD, str STRING FIELD, dbl DOUBLE FIELD);" >/dev/null
out=$(sqt "insert into $DB.t1 (time, dev, i32, f32, str, dbl) values ($(( BASE + 100 )),'d1',42,1.5,'abc',2.5),($(( BASE + 110 )),'d1',43,2.5,'def',3.5);" 2>&1)
printf '%s' "$out" | grep -q successfully && pass "  写入 2 行成功" || fail "  写入失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)"
sqt "flush;" >/dev/null; sleep 5
log "  表结构：$(sqt "desc $DB.t1;" 2>&1 | grep -E '^\|' | tr '\n' ' ' | cut -c1-200)"
log "  初始值：i32=$(dt05_vals i32) f32=$(dt05_vals f32) str=$(dt05_vals str) dbl=$(dt05_vals dbl)"
# 场景有效性：初始值必须真的能取到（不是空串）
assert_eq "  ① 初始 i32 值可读（3 副本同源）" "$(dt05_vals i32)" "42|43|"
assert_eq "  ① 初始行数（数据行，不含表头）" "$(dt05_rows)" "2"

log "--- ② 正向：FIELD 列类型变更（成功 + desc + 值转换）---"
pos(){ local col=$1 to=$2 r ty
  r=$(cmp_alter_col "alter table $DB.t1 alter column $col set data type $to;")
  ty=$(dt05_coltype t1 "$col")
  if printf '%s' "$r" | grep -qi successfully && [ "$ty" = "$to" ]; then
    pass "  [$col → $to] 成功，desc 显示 $ty"
  else
    fail "  [$col → $to] 失败：ty=$ty resp=$(printf '%s' "$r" | cut -c1-140)"
  fi; }
pos i32 INT64
pos i32 DOUBLE
pos f32 DOUBLE
pos str TEXT
pos dbl STRING
log "  改后值：i32=$(dt05_vals i32) f32=$(dt05_vals f32) str=$(dt05_vals str) dbl=$(dt05_vals dbl)"
# ② 值转换语义（这是"数据可读性"的硬判据：数值列按新类型呈现，字符串列原文保留）
assert_eq "  ② i32 列值（INT32→INT64→DOUBLE）" "$(dt05_vals i32)" "42.0|43.0|"
assert_eq "  ② f32 列值（FLOAT→DOUBLE）" "$(dt05_vals f32)" "1.5|2.5|"
assert_eq "  ② str 列值（STRING→TEXT）" "$(dt05_vals str)" "abc|def|"
assert_eq "  ② dbl 列值（DOUBLE→STRING）" "$(dt05_vals dbl)" "2.5|3.5|"
[ "$(dt05_rows)" -ge 2 ] && pass "  改类型后行数未减少（$(dt05_rows) 行）" || fail "  行数异常：$(dt05_rows)"
assert_eq "  三副本查询一致" "$(dt05_all_same "select i32 from $DB.t1 order by time;")" "1"

log "--- ③ 负向：TAG/时间列不可改 + 不兼容类型被拒（701）---"
neg(){ local col=$1 to=$2 want=$3 r
  r=$(cmp_alter_col "alter table $DB.t1 alter column $col set data type $to;")
  if printf '%s' "$r" | grep -qiE "$want"; then
    pass "  [$col → $to] 被正确拒绝：$(printf '%s' "$r" | grep -oE '701: .*' | cut -c1-90)"
  else
    fail "  [$col → $to] 期望报错含 /$want/，实际：$(printf '%s' "$r" | cut -c1-140)"
  fi; }
neg dev STRING 'Can only alter datatype of FIELD'
neg time INT64 'Can only alter datatype of FIELD'
neg dbl FLOAT 'not compatible'
neg str INT32 'not compatible'
neg i32 BOOLEAN 'not compatible'

log "--- ④ 不存在的列/表 → 明确报错 ---"
r=$(cmp_alter_col "alter table $DB.t1 alter column no_such set data type DOUBLE;")
printf '%s' "$r" | grep -qE '701|550|not exist|Unknown' && pass "  不存在的列：$(printf '%s' "$r" | cut -c1-110)" || warn "  不存在列的响应：$(printf '%s' "$r" | cut -c1-120)"
r=$(cmp_alter_col "alter table ${DB}_nope.t1 alter column v set data type DOUBLE;")
printf '%s' "$r" | grep -qE '550|not exist' && pass "  不存在的表：$(printf '%s' "$r" | cut -c1-110)" || warn "  不存在表的响应：$(printf '%s' "$r" | cut -c1-120)"

log "--- 收尾三件套（本用例故意触发过负向改写，这些预期错误列入 benign）---"
export CMP_LOG_BENIGN_EXTRA='not compatible with the existing one|Can only alter datatype of FIELD|Alter (table|column).*(failed)|Status code: (507|508|701|616)|Column .* does not exist|Table .* does not exist|does not exist'
post_checks "select i32 from $DB.t1 order by time;" table
cmp_case_finish "" table ""
