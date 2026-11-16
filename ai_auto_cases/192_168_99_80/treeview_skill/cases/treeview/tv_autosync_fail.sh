#!/bin/bash
# ============================================================================
# TV-12 树侧"新增测点失败"时，树转表视图（auto_sync_schema=true）不得补列
#   失败方式：类型非法 / 路径冲突 / 重复创建（类型不同）/ 无权限 / 非法编码压缩组合
#   对照：失败后重试成功 → 视图应补列；合法新增 → 视图应补列
#   需求：树转表视图自动识别新增测点（TDB-343）只应对"真实新增的测点"生效
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_autosync_fail_${DATA_CONSENSUS}"

DB=db_tv_as
TDB=root.tvas
VIEW=v_as

treeq(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
tree_msg(){ printf '%s\n' "$1" | grep -aE '^(Msg|Error):' | tail -1; }
cols(){ tqt_db "$DB" "desc $VIEW;" | grep -a '^|' | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | grep -avE '^columnname$|^\s*$' | sort | tr '\n' ' '; }
tv=none

tv_prologue "$TDB" "$DB"
tqt "create database $DB;" >/dev/null 2>&1

log "--- 1) 造树库 + 首个测点，建 auto_sync_schema 视图 ---"
treeq "create database $TDB;" >/dev/null 2>&1
treeq "create timeseries $TDB.d1.s1 int32;" >/dev/null 2>&1
treeq "insert into $TDB.d1(time,s1) values(1,1);" >/dev/null 2>&1
out=$(tqt_db "$DB" "create view $VIEW (dev STRING TAG) WITH (auto_sync_schema=true) AS $TDB.**;")
assert_contains "auto_sync_schema 视图创建成功" "$(last_msg "$out")" 'successfully'
BASE=$(cols); log "  基线列：$BASE"
assert_contains "基线含 s1" "$BASE" 's1'

log "--- 2) 失败方式 A：类型非法（701）---"
m=$(tree_msg "$(treeq "create timeseries $TDB.d1.badA datatype=NOTATYPE;")")
if printf '%s' "$m" | grep -qE 'Unsupported datatype|701'; then pass "A 类型非法被拒绝（701 Unsupported datatype）"; else fail "A 类型非法未被拒绝：$m"; fi
sleep 5
c=$(cols)
assert_eq "A 失败后视图列不变" "$c" "$BASE"
assert_not_contains "A 失败后视图无 badA" "$c" 'badA'
assert_not_contains "A 失败后树侧无 badA" "$(strip_echo <<<"$(treeq "show timeseries $TDB.d1.badA;")")" 'badA'

log "--- 3) 失败方式 B：路径冲突（在测点下再建测点）---"
m=$(tree_msg "$(treeq "create timeseries $TDB.d1.s1.sub int32;")")
assert_not_contains "B 路径冲突执行失败" "$m" '^Msg: The statement is executed successfully'
sleep 5
assert_not_contains "B 失败后视图无 sub" "$(cols)" 'sub'
assert_not_contains "B 失败后树侧无 s1.sub" "$(strip_echo <<<"$(treeq "show timeseries $TDB.d1.s1.sub;")")" 's1.sub'

log "--- 4) 失败方式 C：重复创建同名测点（类型不同）---"
m=$(tree_msg "$(treeq "create timeseries $TDB.d1.s2 int64; create timeseries $TDB.d1.s2 int32;")")
assert_not_contains "C 重复创建执行失败" "$m" '^Msg: The statement is executed successfully'
sleep 5
c=$(cols)
assert_contains "C 首个 s2 应被补列（合法新增）" "$c" 's2'
assert_contains "C 视图 s2 类型应为 INT64（不是后来失败的 INT32）" "$(tqt_db "$DB" "desc $VIEW;" | grep -a '| *s2')" 'INT64'

log "--- 5) 失败方式 D：无权限用户创建测点（803）---"
tqt "create user if not exists u_tv_sh only with password 'Tv@12345';" >/dev/null 2>&1
tqt "grant read on $TDB.** to user u_tv_sh;" >/dev/null 2>&1
d=$(printf 'set sql_dialect=tree;\ncreate timeseries %s.d1.badD int32;\n' "$TDB" | "$CLI" -h "${DN[0]}" -u u_tv_sh -pw 'Tv@12345' 2>&1 | grep -aE '^(Msg|Error):' | tail -1)
log "  无权限用户执行结果：$d"
assert_not_contains "D 无权限创建被拒绝" "$d" '^Msg: The statement is executed successfully'
sleep 5
assert_not_contains "D 失败后视图无 badD" "$(cols)" 'badD'
assert_not_contains "D 失败后树侧无 badD" "$(strip_echo <<<"$(treeq "show timeseries $TDB.d1.badD;")")" 'badD'

log "--- 6) 失败方式 E：非法编码/压缩组合 ---"
m=$(tree_msg "$(treeq "create timeseries $TDB.d1.badE text encoding=TS_2DIFF;")")
log "  响应：$m"
if printf '%s' "$m" | grep -qE 'Msg: The statement is executed successfully'; then
  warn "E 非法编码组合未报错（产品允许？仅记录）"
else
  sleep 5
  assert_not_contains "E 失败后视图无 badE" "$(cols)" 'badE'
  assert_not_contains "E 失败后树侧无 badE" "$(strip_echo <<<"$(treeq "show timeseries $TDB.d1.badE;")")" 'badE'
fi

log "--- 7) 对照：失败后重试合法新增（应补列）---"
treeq "create timeseries $TDB.d1.s3 double;" >/dev/null 2>&1
sleep 5
c=$(cols)
assert_contains "合法新增 s3 被补列" "$c" 's3'
assert_contains "s3 类型为 DOUBLE" "$(tqt_db "$DB" "desc $VIEW;" | grep -a '| *s3')" 'DOUBLE'

log "--- 8) 视图查询可用（新列/老列）---"
out=$(tqt_db "$DB" "select count(s1), count(s2), count(s3) from $VIEW;")
assert_not_contains "多列查询无报错" "$out" 'Exception|ERROR'

log "--- 9) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "v_as count" "select count(*), count(s2) from $DB.$VIEW;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
