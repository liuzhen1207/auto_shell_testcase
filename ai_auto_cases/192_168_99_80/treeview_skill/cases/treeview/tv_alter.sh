#!/bin/bash
# ============================================================================
# TV-04 ALTER / COMMENT / DROP 视图（需求 §2.2；含 tree view add column / drop column）
#   ADD COLUMN / RENAME COLUMN / DROP COLUMN / ALTER COLUMN SET DATA TYPE /
#   RENAME TO / SET PROPERTIES(ttl) / COMMENT / DROP VIEW
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_alter_${DATA_CONSENSUS}"

DB=db_tv_alt
LOGD=root.tvalt
tv_prologue "$LOGD" "$DB"

log "--- 1) 造树数据 + 基线视图 ---"
out=$(printf '%s\n' \
"create database $LOGD;" \
"create timeseries $LOGD.d1.temp float;" \
"create timeseries $LOGD.d1.volt double;" \
"create timeseries $LOGD.d1.extra int32;" \
"create timeseries $LOGD.d1.volt2 double;" \
"insert into $LOGD.d1(time,temp,volt,extra) values(1000,1.0,2.0,3);" \
"insert into $LOGD.d1(time,temp,volt,extra) values(2000,4.0,5.0,6);" \
"insert into $LOGD.d1(time,volt2) values(1000,10.0);" \
"insert into $LOGD.d1(time,volt2) values(2000,20.0);" \
"flush;" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "树数据无报错" "$out" 'Exception|ERROR'
tqt "create database $DB;" >/dev/null 2>&1
sleep 1
out=$(tqt_db "$DB" "create view va (dev STRING TAG, temp float) AS $LOGD.**;")
assert_contains "基线视图 va 创建成功" "$(last_msg "$out")" 'successfully'
n0=$(tcol "$(tqt_db "$DB" "select count(*) from va;")" 1)
assert_eq "基线行数=2" "$n0" "2"

log "--- 2) ADD COLUMN：加一个 FIELD 列（tree view add column）---"
out=$(tqt_db "$DB" "alter view va add column volt double field;")
assert_contains "ADD COLUMN volt 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va;")
assert_contains "desc 含新列 volt" "$out" 'volt'
s=$(tcol "$(tqt_db "$DB" "select sum(volt) from va;")" 1)
assert_num_eq "新列数据可查（sum=7）" "$s" "7"

log "--- 3) ADD COLUMN 带 FROM original_measurement（用**未映射**的测点 volt2）---"
out=$(tqt_db "$DB" "alter view va add column v2 double field from volt2;")
assert_contains "ADD COLUMN ... FROM volt2（未映射测点）成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va;")
assert_contains "desc 含别名列 v2" "$out" 'v2'
s2=$(tcol "$(tqt_db "$DB" "select sum(v2) from va;")" 1)
assert_num_eq "新列 v2 数据来自 volt2（sum=30）" "$s2" "30"

log "--- 3b) 负向：FROM 一个**已被映射**的测点（volt 已被同名列占用）---"
out=$(tqt_db "$DB" "alter view va add column vdup double field from volt;")
m=$(last_msg "$out")
if printf '%s' "$m" | grep -qE '552|701|already'; then
  pass "已映射测点被拒绝（一个测点只能映射一个列）"
  # TDB-942：RC2 已把文案改成 "Column 'x' already exists or its source measurement is already mapped"。
  # 回归守护：必须出现"源测点已被映射"这半句；若退回只提"列已存在"（RC1 的误导文案）则判 FAIL。
  if printf '%s' "$m" | grep -qiE 'source measurement|源测点'; then
    pass "TDB-942 文案已澄清（提示源测点已被映射），错误码 552"
  else
    fail "TDB-942 文案退回误导版（只提列已存在，未说明测点已被映射）：$(printf '%s' "$m" | cut -c1-120)"
  fi
else
  fail "已映射测点竟然允许重复加列：$(printf '%s' "$m" | cut -c1-120)"
fi

log "--- 4) ADD COLUMN IF NOT EXISTS 幂等 ---"
out=$(tqt_db "$DB" "alter view va add column if not exists volt double field;")
assert_contains "IF NOT EXISTS 重复加列不报错" "$(last_msg "$out")" 'successfully'

log "--- 5) RENAME COLUMN / DROP COLUMN ---"
out=$(tqt_db "$DB" "alter view va rename column temp to temperature;")
assert_contains "RENAME COLUMN temp→temperature 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va;")
assert_contains "desc 含 temperature" "$out" 'temperature'
out=$(tqt_db "$DB" "alter view va drop column v2;")
assert_contains "DROP COLUMN v2 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va;")
assert_not_contains "desc 不含 v2" "$out" 'v2'

log "--- 6) ALTER COLUMN SET DATA TYPE ---"
out=$(tqt_db "$DB" "alter view va alter column temperature set data type double;")
assert_contains "ALTER COLUMN SET DATA TYPE 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va;")
assert_contains "temperature 类型变为 DOUBLE" "$out" 'DOUBLE'

log "--- 7) SET PROPERTIES(ttl) 与 RENAME TO ---"
out=$(tqt_db "$DB" "alter view va set properties ttl='INF';")
assert_contains "SET PROPERTIES ttl 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "alter view va rename to va2;")
assert_contains "RENAME TO va2 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "show tables;")
assert_contains "show tables 含 va2" "$out" 'va2'
if printf '%s' "$out" | grep -qE '^[[:space:]]*\|[[:space:]]*va[[:space:]]*\|'; then
  fail "show tables 仍含旧名 va（rename 未清理旧条目）"
else
  pass "show tables 不含旧名 va"
fi

log "--- 8) COMMENT ON VIEW / COLUMN ---"
out=$(tqt_db "$DB" "comment on view va2 is 'tree view demo';")
assert_contains "COMMENT ON VIEW 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "comment on column va2.temperature is '温度';")
assert_contains "COMMENT ON COLUMN 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc va2;")
if printf '%s' "$out" | grep -q "tree view demo"; then pass "desc 显示 comment"; else warn "desc 未展示 comment（RC1 行为，记录不判）"; fi

log "--- 9) 查询仍正确（改列名/类型后数据不变）---"
n=$(tcol "$(tqt_db "$DB" "select count(*) from va2;")" 1)
assert_eq "va2 行数仍为 2" "$n" "2"
s=$(tcol "$(tqt_db "$DB" "select sum(temperature) from va2;")" 1)
assert_num_eq "temperature 聚合仍为 5" "$s" "5"

log "--- 10) DROP VIEW 后再查应报错 ---"
out=$(tqt_db "$DB" "drop view va2;")
assert_contains "DROP VIEW 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "select count(*) from va2;")
assert_not_contains "删除后查询应报错" "$(last_msg "$out")" 'successfully'

log "--- 11) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
