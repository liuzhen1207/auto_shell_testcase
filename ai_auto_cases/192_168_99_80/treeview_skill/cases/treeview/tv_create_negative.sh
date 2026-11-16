#!/bin/bash
# ============================================================================
# TV-02 CREATE 负向与 OR REPLACE 语义（需求 §2.1.1.1、§2.1.1.4）
#   prefixPath 规则 / ATTRIBUTE 不支持 / 重复列 / 同一测点两个列 / 无测点 / 类型冲突 /
#   OR REPLACE(view→替换 / table→报错 / 不带 OR REPLACE→报错)
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_create_negative_${DATA_CONSENSUS}"
# 注意：不要放行 "Failures happened during running ConfigExecution" —— 那会把预期内失败造成的 DN WARN 噪声一起放过；
# 该噪声由 cases/treeview/tv_log_noise.sh（TV-LOG-01）严格门禁
TV_LOG_BENIGN_EXTRA="Failed to execute delete database|CreateTable|already exists"

DB=db_tv_neg
LOGD=root.tvneg
tv_prologue "$LOGD" "$DB"

log "--- 1) 造树数据（含两种类型同名列、单设备、多层级）---"
out=$(printf '%s\n' \
"create database $LOGD;" \
"create timeseries $LOGD.s1.d1.temp float;" \
"create timeseries $LOGD.s1.d1.volt double;" \
"create timeseries $LOGD.s1.d1.blob_m blob;" \
"create timeseries $LOGD.s1.d2.temp text;" \
"create timeseries $LOGD.deep.a.b.c.only int64;" \
"insert into $LOGD.s1.d1(time,temp,volt) values(1000,1.0,2.0);" \
"insert into $LOGD.s1.d2(time,temp) values(1000,'x');" \
"insert into $LOGD.deep.a.b.c(time,only) values(1000,7);" \
"flush;" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1)
assert_not_contains "树数据无报错" "$out" 'Exception|ERROR'
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 2) prefixPath 规则：最后一级必须 ** ---"
out=$(tqt_db "$DB" "create view bad1 (t STRING TAG) AS $LOGD.s1.**.temp;")
assert_err_code "中间带 ** 应报错(701 The last node must be **)" "$out" 701
out=$(tqt_db "$DB" "create view bad2 (t STRING TAG) AS $LOGD.s1.*;")
assert_err_code "最后一级是 * 应报错(701)" "$out" 701
out=$(tqt_db "$DB" "create view bad3 (t STRING TAG) AS $LOGD.s1.d1.temp;")
assert_err_code "末级非通配应报错(701)" "$out" 701

log "--- 3) ATTRIBUTE 列不支持（语法层）---"
out=$(tqt_db "$DB" "create view bad4 (t STRING TAG, temp float ATTRIBUTE) AS $LOGD.s1.**;")
assert_not_contains "ATTRIBUTE 列不得创建成功" "$(last_msg "$out")" 'successfully'

log "--- 4) 同一测点被两个列引用（应报错）---"
out=$(tqt_db "$DB" "create view bad5 (t STRING TAG, a float FIELD FROM temp, b float FIELD FROM temp) AS $LOGD.s1.**;")
assert_err_code "同一测点两个列应报错(701 duplicated source measurement)" "$out" 701

log "--- 5) 数据类型在不同设备不一致（temp: d1 float / d2 text）---"
out=$(tqt_db "$DB" "create view bad6 (t STRING TAG, temp FIELD) AS $LOGD.s1.**;")
assert_err_code "同名测点类型冲突应报错(614 Multiple types)" "$out" 614
out=$(tqt_db "$DB" "create view ok6 (t STRING TAG, temp float FIELD) AS $LOGD.s1.**;")
assert_contains "显式指定类型后应可创建" "$(last_msg "$out")" 'successfully'

log "--- 6) 扫描不到测点（前缀下没有叶子）---"
out=$(tqt_db "$DB" "create view bad7 (t STRING TAG, temp FIELD) AS root.nonexist.**;")
assert_err_code "前缀下无测点应报错(528 Measurements not found)" "$out" 528

log "--- 7) 重复列名 ---"
out=$(tqt_db "$DB" "create view bad8 (t STRING TAG, temp float, temp double) AS $LOGD.s1.**;")
assert_err_code "重复列名应报错(701 Columns shall not share the same name)" "$out" 701

log "--- 8) OR REPLACE：view → 替换；table → 报错；不带 OR REPLACE → 报错 ---"
out=$(tqt_db "$DB" "create view vrep (t STRING TAG, temp float) AS $LOGD.s1.**;")
assert_contains "首次创建 vrep 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "create view vrep (t STRING TAG, temp float) AS $LOGD.s1.**;")
assert_not_contains "同名 view 无 OR REPLACE 应报错" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "create or replace view vrep (t STRING TAG, temp float, volt double) AS $LOGD.s1.**;")
assert_contains "OR REPLACE 替换 view 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc vrep;")
assert_contains "替换后新列 volt 生效" "$out" 'volt'
out=$(tqt_db "$DB" "create table tconf (time TIMESTAMP TIME, v INT32 FIELD);")
assert_contains "建普通表 tconf 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "create or replace view tconf (t STRING TAG) AS $LOGD.s1.**;")
assert_not_contains "OR REPLACE 不能覆盖普通表" "$(last_msg "$out")" 'successfully'

log "--- 9) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "ok6 count" "select count(*), sum(temp) from $DB.ok6;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
