#!/bin/bash
# ============================================================================
# TV-09 真实数据：ALTER VIEW（重点：tree view add column）+ 元数据展示
#   需求 §2.2 / §2.3.2 / §2.1.1.4
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_real_alter_${DATA_CONSENSUS}"

DB=db_tv_ra
P=${TV_DATA_DEV:-root.reactor.system1.techSystem1.DX.HYH_W3.AA5}
T0=${TV_WIN_T0:-2024-11-21T08:00:00}
T1=${TV_WIN_T1:-2024-11-21T08:10:00}
tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }

tv_prologue_keep "$DB"
tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 1) 基线视图（1 个 FIELD）---"
out=$(tqt_db "$DB" "create view ra (sensor_id STRING TAG, value float field) AS $P.**;")
assert_contains "基线视图 ra 创建成功" "$(last_msg "$out")" 'successfully'
S=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$P" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
    | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')
c0=$(tcol "$(tqt_db "$DB" "select count(*) from ra where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
log "  基线行数=$c0  sensor=$S"

log "--- 2) tree view add column：用**未被映射**的测点（正向）---"
# 在真实数据的某个传感器下补一个测点 value2（AA5.** 视图里 value 已被列 v 映射，不能再用）
TREE_Q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
TREE_Q "create timeseries $P.$S.value2 float; insert into $P.$S(time,value2) values(2024-11-21T08:00:00+08:00,9.5);" >/dev/null 2>&1
sleep 2
out=$(tqt_db "$DB" "alter view ra add column value2 float field from value2;")
assert_contains "ADD COLUMN value2 FROM value2（未映射测点）成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc ra;")
assert_contains "desc 含新列 value2" "$out" 'value2'
v=$(tcol "$(tqt_db "$DB" "select count(*) from ra where sensor_id='$S' and value2 is not null and time >= $T0 and time < $T1;")" 1)
# 源测点 value2 只写了 1 个点（见步骤 2 的 insert），所以新列只该有 1 行，不能拿基线 112 行比
assert_num_eq "新列 value2 行数 = 1（源测点只写了 1 个点）" "$v" "1"

log "--- 2b) 负向：用**已被列映射**的测点 FROM value（应被拒绝，并记录文案）---"
out=$(tqt_db "$DB" "alter view ra add column dup float field from value;")
if printf '%s' "$(last_msg "$out")" | grep -qE '552|701|already'; then
  pass "同测点重复映射被拒绝（符合需求：一个测点只能一个列）"
  # TDB-942：RC2 文案已澄清（"... or its source measurement is already mapped"），错误码仍 552。
  # 回归守护：必须出现"源测点已被映射"这半句；退回 RC1 误导文案则 FAIL。
  if printf '%s' "$(last_msg "$out")" | grep -qiE 'source measurement|源测点'; then
    pass "TDB-942 文案已澄清（提示源测点已被映射），错误码 552"
  else
    fail "TDB-942 文案退回误导版：$(printf '%s' "$(last_msg "$out")" | cut -c1-120)"
  fi
else
  fail "同测点重复映射竟然成功：$(printf '%s' "$(last_msg "$out")" | cut -c1-160)"
fi

log "--- 3) ADD COLUMN IF NOT EXISTS 幂等 ---"
out=$(tqt_db "$DB" "alter view ra add column if not exists value2 float field from value;")
assert_contains "IF NOT EXISTS 不报错" "$(last_msg "$out")" 'successfully'

log "--- 4) RENAME COLUMN / DROP COLUMN ---"
out=$(tqt_db "$DB" "alter view ra rename column value2 to value3;")
assert_contains "RENAME COLUMN value2→value3 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc ra;")
assert_contains "desc 含 value3" "$out" 'value3'
out=$(tqt_db "$DB" "alter view ra drop column value3;")
assert_contains "DROP COLUMN value3 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc ra;")
assert_not_contains "desc 不再含 value3" "$out" 'value3'

log "--- 5) RENAME TO / COMMENT ---"
out=$(tqt_db "$DB" "alter view ra rename to ra2;")
assert_contains "RENAME TO ra2 成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "show tables;")
assert_contains "show tables 含 ra2" "$out" 'ra2'
out=$(tqt_db "$DB" "comment on view ra2 is 'real tree view';")
assert_contains "COMMENT ON VIEW 成功" "$(last_msg "$out")" 'successfully'

log "--- 6) show create view（DDL 可解析性）---"
out=$(tqt_db "$DB" "show create view ra2;")
ddl=$(printf '%s' "$out" | grep -a 'CREATE VIEW' | head -1 | sed 's/^|//; s/|$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
log "  DDL=${ddl:0:220}"
assert_contains "show create view 含 CREATE VIEW" "$out" 'CREATE VIEW'
assert_contains "DDL 含 TAG/FIELD" "$out" 'TAG'

log "--- 7) 改列类型 + 数据仍可查 ---"
out=$(tqt_db "$DB" "alter view ra2 alter column value set data type double;")
assert_contains "ALTER COLUMN SET DATA TYPE 成功" "$(last_msg "$out")" 'successfully'
v=$(tcol "$(tqt_db "$DB" "select count(*) from ra2 where sensor_id='$S' and time >= $T0 and time < $T1;")" 1)
assert_num_eq "改类型后行数不变" "$v" "$c0"

log "--- 8) 收尾三件套 ---"
tv_sync_lag 90 || true
tv_replica_consistency "ra2 单传感器 count" "select count(*) from $DB.ra2 where sensor_id='$S' and time >= $T0 and time < $T1;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
