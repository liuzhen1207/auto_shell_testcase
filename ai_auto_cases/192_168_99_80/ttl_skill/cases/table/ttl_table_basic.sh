#!/bin/bash
# ============================================================================
# TB-01 表模型 TTL 基本功能与参数值
#   粒度：database / 表 / 视图
#   覆盖：CREATE DATABASE WITH(ttl)、CREATE TABLE WITH(ttl)、ALTER TABLE/VIEW、
#         TTL='INF'/default、库→表继承与解耦、SHOW TABLES、SHOW DATABASES DETAILS、
#         information_schema、参数非法值(701/700)、树模型不支持 OBJECT 的负向验证
# 用法： bash ttl_table_basic.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_table_basic_${DATA_CONSENSUS}"

TDB=ttl_tdb
TDB2=ttl_tdb2
# 表模型语句需要先 use database；同一会话里执行 use + 语句
tq(){ sql_lines_table "use $TDB;" "$@"; }
iq(){ sql_lines_table "use $TDB;" "$1"; }

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) CREATE DATABASE WITH (ttl=...)：库级 TTL ---"
out=$(sql_lines_table "create database $TDB with (ttl=60000);")
assert_contains "建库(带 ttl)成功" "$out" "successfully"
out=$(sql_lines_table "select database, \"ttl(ms)\" from information_schema.databases;")
log "  information_schema.databases: $(rows_of "$out" | tr '\n' ' ')"
assert_eq "库 TTL=60000" "$(row_col "$out" "$TDB" 2)" "60000"

log "--- 2) CREATE TABLE：显式 TTL / 继承库 / 'INF' / default ---"
out=$(tq "create table t_ttl (dev string tag, v double field) with (ttl=120000);")
assert_contains "建表 t_ttl(ttl=120000) 成功" "$out" "successfully"
out=$(tq "create table t_inherit (dev string tag, v double field);")
assert_contains "建表 t_inherit(无 ttl) 成功" "$out" "successfully"
out=$(tq "create table t_inf (dev string tag, v double field) with (ttl='INF');")
assert_contains "建表 t_inf(ttl='INF') 成功" "$out" "successfully"
out=$(tq "create table t_default (dev string tag, v double field) with (ttl=default);")
assert_contains "建表 t_default(ttl=default) 成功" "$out" "successfully"
out=$(tq "show tables;")
log "  SHOW TABLES:"; printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"
assert_eq "t_ttl 表 TTL"        "$(table_ttl "$out" t_ttl)"     "120000"
assert_eq "t_inherit 继承库 TTL" "$(table_ttl "$out" t_inherit)" "60000"
assert_eq "t_inf 表 TTL=INF"     "$(table_ttl "$out" t_inf)"     "INF"
assert_eq "t_default 继承库 TTL" "$(table_ttl "$out" t_default)" "60000"
out=$(tq "select table_name, \"ttl(ms)\" from information_schema.tables where database='$TDB';")
assert_eq "information_schema: t_ttl"     "$(row_col "$out" "t_ttl" 2)"     "120000"
assert_eq "information_schema: t_inherit" "$(row_col "$out" "t_inherit" 2)" "60000"

log "--- 3) ALTER TABLE SET PROPERTIES ttl ---"
out=$(tq "alter table t_ttl set properties ttl=60000;")
assert_contains "alter table ttl=60000 成功" "$out" "successfully"
out=$(tq "show tables;")
assert_eq "改后 t_ttl=60000" "$(table_ttl "$out" t_ttl)" "60000"
out=$(tq "alter table t_ttl set properties ttl='INF';")
assert_contains "alter table ttl='INF' 成功" "$out" "successfully"
out=$(tq "show tables;")
assert_eq "改后 t_ttl=INF" "$(table_ttl "$out" t_ttl)" "INF"

log "--- 4) 参数非法值：负数/小数/超范围 ---"
out=$(tq "alter table t_ttl set properties ttl=-1000;")
assert_error_code "负数 TTL 被拒(701)" "$out" "701"
out=$(tq "alter table t_ttl set properties ttl=0.001;")
assert_error_code "小数 TTL 被拒(701)" "$out" "701"
out=$(tq "alter table t_ttl set properties ttl=9223372036854775808;")
assert_error_code "超出 long 的 TTL 被拒(700)" "$out" "700"

log "--- 5) ALTER DATABASE 改库 TTL：不影响已有表，新表继承新值 ---"
out=$(sql_lines_table "alter database $TDB set properties ttl='INF';")
assert_contains "alter database ttl='INF' 成功" "$out" "successfully"
out=$(sql_lines_table "select database, \"ttl(ms)\" from information_schema.databases;")
assert_eq "库 TTL 改为 INF" "$(row_col "$out" "$TDB" 2)" "INF"
out=$(tq "show tables;")
assert_eq "已有表 t_inherit 不受库改动影响" "$(table_ttl "$out" t_inherit)" "60000"
out=$(tq "create table t_new (dev string tag, v double field);")
assert_contains "库 TTL=INF 后建新表成功" "$out" "successfully"
out=$(tq "show tables;")
assert_eq "新表继承 INF" "$(table_ttl "$out" t_new)" "INF"

log "--- 6) 视图 TTL：创建/查询/修改 ---"
out=$(tq "create writable view v_ttl as select dev, v from t_inherit with (ttl=30000);")
assert_contains "建视图 v_ttl(ttl=30000) 成功" "$out" "successfully"
out=$(tq "select table_name, \"ttl(ms)\" from information_schema.tables;")
log "  information_schema.tables: $(rows_of "$out" | tr '\n' ' ')"
assert_eq "视图 v_ttl TTL=30000" "$(row_col "$out" "v_ttl" 2)" "30000"
out=$(tq "alter view v_ttl set properties ttl=60000;")
assert_contains "alter view ttl=60000 成功" "$out" "successfully"
out=$(tq "select table_name, \"ttl(ms)\" from information_schema.tables;")
assert_eq "视图 v_ttl TTL 改为 60000" "$(row_col "$out" "v_ttl" 2)" "60000"

log "--- 7) SHOW DATABASES DETAILS 含 TTL(ms) 列 ---"
out=$(sql_lines_table "show databases details;")
assert_contains "SHOW DATABASES DETAILS 有 TTL(ms) 列" "$out" "TTL\(ms\)"

log "--- 8) 负向验证：树模型不支持 OBJECT ---"
out=$(sq "create timeseries root.neg_obj.d1.o1 with datatype=OBJECT;")
if printf '%s\n' "$out" | grep -qiE 'IoTDBSQLException|error|Exception'; then pass "树模型建 OBJECT 序列被拒（如期）"; else fail "树模型竟然支持 OBJECT 序列"; fi
out=$(sq "create database root.neg_obj;" ; sq "insert into root.neg_obj.d1(time,o1) values($(now_ms), to_object(true, 0, X'62'));")
if printf '%s\n' "$out" | grep -qiE 'IoTDBSQLException|error|Exception'; then pass "树模型写 OBJECT 被拒（如期）"; else fail "树模型竟然支持 OBJECT 写入"; fi

log "--- 9) 清理 ---"
sq "unset ttl from root.neg_obj;" >/dev/null 2>&1 || true
sq "drop database root.neg_obj;"  >/dev/null 2>&1 || true

log "--- 10) 集群面收尾检查（sync lag -> 副本一致性 -> 日志） ---"
post_checks "select count(*) from $TDB.t_inherit;" table
ttl_case_finish "" table ""
