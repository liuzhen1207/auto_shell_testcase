#!/bin/bash
# ============================================================================
# TV-01 CREATE 基本信息面：显式列定义 / 类型 / TAG-FIELD 映射 / FROM 改名 / 无 FIELD 扫描 / time 列
#   需求点（树转表需求分析 §2.1.1、§2.1.1.4、§2.1.2、§2.4）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_create_basic_${DATA_CONSENSUS}"

DB=db_tv
tv_cluster_prepare >/dev/null 2>&1
tv_set_consensus
tv_log_mark
tv_host_ready(){ local i; for i in $(seq 1 40); do tqt "show databases;" >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }
tv_host_ready || { fail "集群未就绪"; tv_case_finish; exit 1; }

log "--- 0) 清掉本用例的库（表/树各一），保证干净起点 ---"
tv_reset_db "$DB" table
tv_reset_db root.tvdb tree
sleep 2

log "--- 1) 造受控树模型数据（覆盖多类型 + 多层级 + 测点改名）---"
lines=$(cat <<'SQL'
create database root.tvdb;
create timeseries root.tvdb.sg.d1.temp float;
create timeseries root.tvdb.sg.d1.volt double;
create timeseries root.tvdb.sg.d1.status int32;
create timeseries root.tvdb.sg.d1.speed float;
create timeseries root.tvdb.sg.d2.temp float;
create timeseries root.tvdb.sg.d2.volt double;
create timeseries root.tvdb.sub.sg2.d3.temp float;
insert into root.tvdb.sg.d1(time,temp,volt,status,speed) values(1000,1.5,2.5,1,10.0);
insert into root.tvdb.sg.d1(time,temp,volt,status,speed) values(2000,2.5,3.5,2,20.0);
insert into root.tvdb.sg.d2(time,temp,volt) values(1000,3.5,4.5);
insert into root.tvdb.sg.d2(time,temp,volt) values(2000,4.5,5.5);
insert into root.tvdb.sub.sg2.d3(time,temp) values(1000,5.5);
insert into root.tvdb.sub.sg2.d3(time,temp) values(2000,6.5);
flush;
SQL
)
out=$(printf '%s\n' "$lines" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "树模型造数据无报错" "$out" 'Exception|ERROR'
for h in "${DN[@]}"; do
  r=$(sshx "$h" "printf 'set sql_dialect=tree;\nselect count(temp) from root.tvdb.**;\n' | $CLI -h $h -u root -pw '$ROOT_PW' 2>&1" | table_rows | wc -l)
done
tv_sync_lag 40

tqt "create database $DB;" >/dev/null 2>&1
scope="root.tvdb.sg.**"

log "--- 2) 显式 TAG + 多 FIELD + 显式类型：期望创建成功 ---"
out=$(tqt_db "$DB" "create view v1 (region STRING TAG, temp float field, volt double field) AS $scope;")
assert_contains "v1 创建成功（显式 TAG/FIELD/类型）" "$(last_msg "$out")" 'successfully'

log "--- 3) 视图列结构：desc 应含 time/region/temp/volt，且不含未声明列 ---"
out=$(tqt_db "$DB" "desc v1;")
rows=$(printf '%s' "$out" | table_rows)
assert_contains "v1 含 region 列" "$rows" 'region'
assert_contains "v1 含 temp 列" "$rows" 'temp'
assert_contains "v1 含 volt 列" "$rows" 'volt'
assert_not_contains "v1 不含未声明的 status 列" "$rows" 'status'

log "--- 4) 无 FIELD 列：应扫描前缀子树下全部测点 ---"
out=$(tqt_db "$DB" "create view v2 (region STRING TAG) AS root.tvdb.sg.**;")
assert_contains "v2 创建成功（无 FIELD 自动扫描）" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc v2;")
rows=$(printf '%s' "$out" | table_rows)
for m in temp volt status speed; do assert_contains "v2 扫描出测点 $m" "$rows" "$m"; done

log "--- 5) FROM original_measurement：把树测点改名成列 ---"
out=$(tqt_db "$DB" "create view v3 (region STRING TAG, temperature float FIELD FROM temp, voltage double FIELD FROM volt) AS root.tvdb.sg.**;")
assert_contains "v3 创建成功（列改名）" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "select temperature, voltage from v3 order by time limit 1;")
assert_not_contains "v3 查询无报错" "$out" 'Exception|ERROR'

log "--- 6) dataType 自动推断（不写类型）---"
out=$(tqt_db "$DB" "create view v4 (region STRING TAG, temp FIELD) AS root.tvdb.sg.**;")
assert_contains "v4 创建成功（类型自动推断）" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc v4;")
assert_contains "v4 temp 列类型推断为 FLOAT" "$out" 'FLOAT'

log "--- 7) 查询与树模型对照（行数/聚合一致）---"
tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
tv_c=$(tcol "$(tqt "select count(*) from $DB.v1;")" 1)
tree_c=$(row_sum "$(tree_q "select count(temp) from root.tvdb.sg.**;")")
assert_num_eq "视图 v1 行数与树模型一致" "$tv_c" "$tree_c"

tv_s=$(tcol "$(tqt "select sum(temp) from $DB.v1;")" 1)
tree_s=$(row_sum "$(tree_q "select sum(temp) from root.tvdb.sg.**;")")
assert_num_eq "视图 v1 sum(temp) 与树模型一致" "$tv_s" "$tree_s"

log "--- 8) 视图只读（不能写）---"
out=$(tqt_db "$DB" "insert into v1(time,region,temp) values (3000,'x',9.9);")
assert_not_contains "通过视图写入应被拒绝" "$(last_msg "$out")" 'successfully'

log "--- 9) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "v1 count/sum" "select count(*), sum(temp) from $DB.v1;"
tv_check_logs "$(awk '$1=="'"${HOSTS[0]}"'"{print $2}' "$ART/log_marks.txt" 2>/dev/null || echo 0)" "CN/DN 日志"

tv_case_finish
