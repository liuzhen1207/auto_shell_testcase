#!/bin/bash
# ============================================================================
# TV-05 视图展示面（需求 §2.3）
#   SHOW TABLES 的 TABLE_TYPE（BASE TABLE / VIEW FROM TREE / SYSTEM VIEW）
#   SHOW CREATE TABLE / VIEW（完整性、跨 database 可复现）
#   DESC / information_schema.tables 一致性
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_show_${DATA_CONSENSUS}"

DB=db_tv_show
LOGD=root.tvshow
tv_prologue "$LOGD" "$DB"

log "--- 0) 强制清掉本用例的库（防上一轮残留：tv1/base1/root.tvshow）---"
tqt "drop database $DB;" >/dev/null 2>&1
printf 'set sql_dialect=tree;\ndrop database %s;\n' "$LOGD" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
sleep 2
tqt "create database $DB;" >/dev/null 2>&1
log "  清理后 show databases 里 $DB 是否存在：$(tqt "show databases;" | grep -ac "$DB")"

log "--- 1) 造数据：一个基础表 + 一个树视图 ---"
out=$(printf '%s\n' \
"create database $LOGD;" \
"create timeseries $LOGD.d1.temp float;" \
"create timeseries $LOGD.d1.volt double;" \
"insert into $LOGD.d1(time,temp,volt) values(1000,1.0,2.0);" \
"flush;" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
if printf '%s' "$out" | grep -aE 'Exception|ERROR' | grep -avqE 'already been created|already exists|already exist'; then
  fail "树数据无报错 :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
else
  pass "树数据无报错（已存在类错误视为幂等噪声）"
fi
tqt "create database $DB;" >/dev/null 2>&1
sleep 1
tqt_db "$DB" "create table base1 (time TIMESTAMP TIME, v INT32 FIELD);" >/dev/null 2>&1
out=$(tqt_db "$DB" "create view tv1 (dev STRING TAG, temp float, volt double) AS $LOGD.**;")
assert_contains "tv1 创建成功" "$(last_msg "$out")" 'successfully'

log "--- 2) SHOW TABLES 的 TABLE_TYPE ---"
out=$(tqt_db "$DB" "show tables;")
low=$(printf '%s' "$out" | tr 'A-Z' 'a-z')
log "  show tables 原文：$(printf '%s' "$out" | grep -a '^|' | tr '\n' ' ' | cut -c1-300)"
assert_contains "show tables 列出 base1" "$low" 'base1'
assert_contains "show tables 列出 tv1（视图与表同列）" "$low" 'tv1'

log "--- 2b) SHOW TABLES DETAILS 的 TableType（需求 §2.3.1 的 TABLE_TYPE）---"
out=$(tqt_db "$DB" "show tables details;")
log "  show tables details 原文：$(printf '%s' "$out" | grep -a '^|' | tr '\n' ' ' | cut -c1-340)"
assert_contains "details 含 TableType 列" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" 'tabletype'
assert_contains "base1 类型为 BASE TABLE" "$out" 'BASE TABLE'
assert_contains "tv1 类型为 VIEW FROM TREE" "$out" 'VIEW FROM TREE'
assert_contains "details 带 OriginalTableName 列（视图来源）" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" 'originaltablename'

log "--- 3) information_schema 里的 TABLE_TYPE ---"
out=$(tqt "select table_name, table_type from information_schema.tables where database='$DB';")
assert_contains "information_schema 含 tv1" "$out" 'tv1'
assert_contains "information_schema 标注 VIEW FROM TREE" "$out" 'VIEW FROM TREE'
assert_contains "information_schema 标注 BASE TABLE" "$out" 'BASE TABLE'

log "--- 4) SHOW CREATE VIEW：应给出完整可复现 DDL ---"
out=$(tqt_db "$DB" "show create view tv1;")
log "  show create view 原文：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
assert_contains "show create view 含 CREATE VIEW" "$out" 'CREATE VIEW'
assert_contains "含 TAG 列定义" "$out" 'TAG'
assert_contains "含 FIELD 列定义" "$out" 'FIELD'
assert_contains "含 prefixPath（带引号形式）" "$out" '**'

log "--- 5) SHOW CREATE TABLE：view 也可展示，且与 show create view 一致 ---"
out_v=$(tqt_db "$DB" "show create view tv1;" | grep -a 'CREATE VIEW' | head -1 | sed 's/[[:space:]]\+/ /g')
out_t=$(tqt_db "$DB" "show create table tv1;" | grep -a 'CREATE VIEW' | head -1 | sed 's/[[:space:]]\+/ /g')
assert_eq "show create table 与 show create view 一致" "$out_t" "$out_v"

log "--- 6) 展示的 DDL 可在新 database 复现同一视图 ---"
# 复现目标库每次先 drop（否则上一轮的视图还在 → 551 already exists）
tqt "drop database ${DB}2;" >/dev/null 2>&1
sleep 1
out=$(tqt "create database ${DB}2;")
# show create view 是表格形态：| viewName|CREATE VIEW "..." (...) WITH (...) AS root."db".**|
ddl=$(printf '%s' "$out_v" | grep -a 'CREATE VIEW' | head -1 | sed 's/^|//' | cut -d'|' -f2- | sed 's/|$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
log "  取出的 DDL：${ddl:0:200}"
out=$(printf 'set sql_dialect=table;\nuse %s;\n%s;\n' "${DB}2" "$ddl" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_contains "按 show create 的 DDL 复现成功" "$(last_msg "$out")" 'successfully'
n1=$(tcol "$(tqt_db "$DB" "select count(*) from tv1;")" 1)
n2=$(tcol "$(tqt_db "${DB}2" "select count(*) from tv1;")" 1)
assert_eq "复现出的视图行数一致" "$n2" "$n1"

log "--- 7) DESC 视图列信息 ---"
out=$(tqt_db "$DB" "desc tv1;")
rows=$(printf '%s' "$out" | grep -a '^|')
assert_contains "desc 含 time/TIMESTAMP" "$rows" 'TIMESTAMP'
assert_contains "desc 含 TAG 类别" "$rows" 'TAG'
assert_contains "desc 含 FIELD 类别" "$rows" 'FIELD'

log "--- 8) show create 作用在普通表 / information_schema 上的边界 ---"
out=$(tqt_db "$DB" "show create view base1;")
assert_not_contains "show create view 对普通表应报错" "$(last_msg "$out")" 'successfully'
out=$(tqt "show create table information_schema.tables;")
assert_not_contains "show create table 对 information_schema 应报错" "$(last_msg "$out")" 'successfully'

log "--- 9) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "tv1 count" "select count(*), sum(temp) from $DB.tv1;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
