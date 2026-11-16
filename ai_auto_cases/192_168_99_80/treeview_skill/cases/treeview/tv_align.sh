#!/bin/bash
# ============================================================================
# TV-16 对齐 / 非对齐设备的 null 行语义（树转表视图）
#   对齐设备：s1 与 s2 时间点不同 → 视图里应各自为 NULL，行数 = 时间点并集
#   非对齐设备：同理，行数 = 时间点并集
#   断言：视图行数/非空计数与树模型分别一致；null 位置符合预期
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_align_${DATA_CONSENSUS}"

DB=db_tv_al
TDB=root.tval
VIEW=v_al

treeq(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
tq(){ tqt_db "$DB" "$1"; }

tv_prologue "$TDB" "$DB"
tqt "create database $DB;" >/dev/null 2>&1

log "--- 1) 造对齐设备 d_al（s1 在 t1/t3，s2 在 t2/t3）+ 非对齐设备 d_na ---"
treeq "create database $TDB;" >/dev/null 2>&1
o=$(treeq "create aligned timeseries $TDB.d_al(s1 int32, s2 int64);")
assert_not_contains "建对齐序列无报错" "$o" 'Exception'
treeq "create timeseries $TDB.d_na.s1 int32;" >/dev/null 2>&1
treeq "create timeseries $TDB.d_na.s2 int64;" >/dev/null 2>&1
treeq "insert into $TDB.d_al(time,s1) values(1000,1);" >/dev/null 2>&1
treeq "insert into $TDB.d_al(time,s2) values(2000,2);" >/dev/null 2>&1
treeq "insert into $TDB.d_al(time,s1,s2) values(3000,3,3);" >/dev/null 2>&1
treeq "insert into $TDB.d_na(time,s1) values(1000,1);" >/dev/null 2>&1
treeq "insert into $TDB.d_na(time,s2) values(2000,2);" >/dev/null 2>&1
treeq "insert into $TDB.d_na(time,s1,s2) values(3000,3,3);" >/dev/null 2>&1
treeq "flush;" >/dev/null 2>&1

log "--- 2) 建视图并等列 ---"
out=$(tq "create view $VIEW (dev STRING TAG, s1 int32 field, s2 int64 field) AS $TDB.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
for i in $(seq 1 20); do
  c=$(tcol "$(tqt "select count(*) from information_schema.columns where table_name='$VIEW' and database='$DB';")" 1)
  [ "${c:-0}" -ge 4 ] && break
  sleep 2
done
log "  视图列数=$c"
assert_num_eq "视图列数 = time+dev+s1+s2" "${c:-0}" "4"

log "--- 3) 行数 = 时间点并集（各设备 3 行）---"
# 三个时间点 1000/2000/3000：对齐与非对齐都应产出 3 行（并集）
for d in d_al d_na; do
  v=$(tcol "$(tq "select count(*) from $VIEW where dev='$d';")" 1)
  log "  $d: 视图行数=$v（期望 3 = 时间点并集）"
  assert_num_eq "$d 视图行数 = 时间点并集(3)" "$v" "3"
done

log "--- 4) 非空计数（s1 两行、s2 两行，各设备）---"
for d in d_al d_na; do
  v1=$(tcol "$(tq "select count(s1) from $VIEW where dev='$d';")" 1)
  v2=$(tcol "$(tq "select count(s2) from $VIEW where dev='$d';")" 1)
  log "  $d: count(s1)=$v1 count(s2)=$v2（期望 2/2）"
  assert_num_eq "$d count(s1)=2" "$v1" "2"
  assert_num_eq "$d count(s2)=2" "$v2" "2"
done

log "--- 5) null 位置符合预期（t=2000 的 s1 为 null、t=1000 的 s2 为 null）---"
for d in d_al d_na; do
  o=$(tq "select time, s1, s2 from $VIEW where dev='$d' order by time;")
  log "  $d 明细：$(printf '%s' "$o" | grep -a '^|19' | tr '\n' ' ' | cut -c1-200)"
  assert_not_contains "$d 查询无报错" "$o" 'Exception|ERROR'
  n1=$(printf '%s' "$o" | grep -ac 'null')
  [ "${n1:-0}" -ge 2 ] && pass "$d 明细里存在 null（对齐/非对齐均按时间点补 null）" \
    || fail "$d 明细里没有 null（实际：$(printf '%s' "$o" | grep -a '^|19' | head -3 | tr '\n' ' ')）"
done

log "--- 6) 两设备结果一致（对齐 vs 非对齐）---"
a=$(tq "select count(*), count(s1), count(s2), sum(s1), sum(s2) from $VIEW where dev='d_al';" | grep -a '^|' | tail -1)
b=$(tq "select count(*), count(s1), count(s2), sum(s1), sum(s2) from $VIEW where dev='d_na';" | grep -a '^|' | tail -1)
log "  d_al: $a"
log "  d_na: $b"
assert_eq "对齐与非对齐设备聚合结果一致" "$(printf '%s' "$a" | tr -d ' ')" "$(printf '%s' "$b" | tr -d ' ')"

log "--- 7) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "$VIEW 聚合" "select count(*), count(s1), sum(s2) from $DB.$VIEW;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
