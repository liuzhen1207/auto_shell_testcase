#!/bin/bash
# ============================================================================
# TV-15 性能：树转表视图 vs 普通表（同数据量）
#   50k 点（100 设备 × 500 行），三次取最小，断言：结果一致 + 视图耗时 ≤ 3× 普通表
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_perf_${DATA_CONSENSUS}"

DB=db_tv_perf
TDB=root.tvp
VIEW=v_perf
NDEV=${TV_PERF_DEV:-100}
NROW=${TV_PERF_ROW:-500}

treeq(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
tq(){ tqt_db "$DB" "$1"; }
best3(){ # best3 <sql-dialect> <sql> -> 最小毫秒
  local d=$1 sql=$2 i t m=999999
  for i in 1 2 3; do
    t=$(date +%s%3N)
    printf 'set sql_dialect=%s;\n%s\n' "$d" "$sql" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
    local e=$(date +%s%3N)
    t=$(( e - t )); [ "$t" -lt "$m" ] && m=$t
  done
  echo "$m"
}

tv_prologue "$TDB" "$DB"
tqt "create database $DB;" >/dev/null 2>&1

log "--- 1) 造 $NDEV 设备 × $NROW 行（树模型）---"
treeq "create database $TDB;" >/dev/null 2>&1
for d in $(seq 1 "$NDEV"); do
  echo "create timeseries $TDB.d$d.v int32;" >>/tmp/tvp_create.sql
done
{ echo "set sql_dialect=tree;"; cat /tmp/tvp_create.sql; } | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
rm -f /tmp/tvp_create.sql
t0=$(date +%s)
for d in $(seq 1 "$NDEV"); do
  : >/tmp/tvp_ins.sql
  for ((i=1;i<=NROW;i+=50)); do
    printf 'insert into %s.d%s(time,v) values' "$TDB" "$d" >>/tmp/tvp_ins.sql
    for ((j=i;j<i+50 && j<=NROW;j++)); do printf '(%d,%d)' "$j" "$j" >>/tmp/tvp_ins.sql; [ $j -lt $((i+49)) ] && [ $j -lt "$NROW" ] && printf ',' >>/tmp/tvp_ins.sql; done
    printf ';\n' >>/tmp/tvp_ins.sql
  done
  { echo "set sql_dialect=tree;"; cat /tmp/tvp_ins.sql; } | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
done
rm -f /tmp/tvp_ins.sql
treeq "flush;" >/dev/null 2>&1
log "  写入耗时 $(( $(date +%s) - t0 ))s"
n=$(treeq "count timeseries $TDB.**;" | grep -a '^|' | tail -1 | tr -dc '0-9')
assert_num_eq "树侧序列数" "${n:-0}" "$NDEV"

log "--- 2) 建视图 + 等列补齐 ---"
out=$(tqt_db "$DB" "create view $VIEW (dev STRING TAG, v int32 field) AS $TDB.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
for i in $(seq 1 30); do
  c=$(tcol "$(tqt "select count(*) from information_schema.columns where table_name='$VIEW' and database='$DB';")" 1)
  [ "${c:-0}" -ge 3 ] && break
  sleep 2
done
log "  视图列数=$c"

log "--- 3) 同样的数据落到普通表 ---"
tq "create table t_perf (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
for d in $(seq 1 "$NDEV"); do
  : >/tmp/tvp_tins.sql
  for ((i=1;i<=NROW;i+=50)); do
    printf 'insert into t_perf(time,dev,v) values' >>/tmp/tvp_tins.sql
    for ((j=i;j<i+50 && j<=NROW;j++)); do printf "(%d,'d%d',%d)" "$j" "$d" "$j" >>/tmp/tvp_tins.sql; [ $j -lt $((i+49)) ] && [ $j -lt "$NROW" ] && printf ',' >>/tmp/tvp_tins.sql; done
    printf ';\n' >>/tmp/tvp_tins.sql
  done
  { echo "set sql_dialect=table;"; echo "use $DB;"; cat /tmp/tvp_tins.sql; } | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
done
rm -f /tmp/tvp_tins.sql
tv_sync_lag 60 || true

log "--- 4) 结果一致性 ---"
vs=$(tcol "$(tq "select count(*), sum(v) from $VIEW;")" 1)
re=$(printf '%s' "$(tq "select count(*), sum(v) from $VIEW;")" | grep -a '^|' | tail -1 | awk -F'|' '{gsub(/ /,"",$2);print $2}')
ts=$(printf '%s' "$(tq "select count(*), sum(v) from t_perf;")" | grep -a '^|' | tail -1 | awk -F'|' '{gsub(/ /,"",$2);print $2}')
log "  视图 count=$re  普通表 count=$ts"
assert_num_eq "视图与普通表行数一致" "$re" "$ts"
ve=$(printf '%s' "$(tq "select count(*), sum(v) from $VIEW;")" | grep -a '^|' | tail -1 | awk -F'|' '{gsub(/ /,"",$3);print $3}')
te=$(printf '%s' "$(tq "select count(*), sum(v) from t_perf;")" | grep -a '^|' | tail -1 | awk -F'|' '{gsub(/ /,"",$3);print $3}')
assert_num_eq "视图与普通表 sum 一致" "$ve" "$te"

log "--- 5) 性能（各 3 次取最小，单位 ms）---"
mv=$(best3 table "select count(*), sum(v) from $VIEW;")
mt=$(best3 table "select count(*), sum(v) from t_perf;")
mg=$(best3 tree  "select count(v), sum(v) from $TDB.**;")
log "  视图=$mv ms  普通表=$mt ms  树模型=$mg ms"
assert_ne "视图查询耗时非 0" "$mv" "0"
ratio=$(awk -v a="$mv" -v b="$mt" 'BEGIN{ if (b<=0) {print 0} else {printf "%.2f", a/b} }')
log "  视图/普通表 = ${ratio}x（阈值 ≤ 3.0）"
if awk -v r="$ratio" 'BEGIN{exit !(r <= 3.0)}'; then
  pass "视图查询耗时在普通表 3 倍以内（${ratio}x）"
else
  fail "视图查询明显慢于普通表（${ratio}x > 3.0）"
fi

log "--- 6) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "$VIEW 单设备 count" "select count(*) from $DB.$VIEW where dev='d1';"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
