#!/bin/bash
# ============================================================================
# TV-14 树转表视图的权限（§2.7）
#   1) 只有视图 SELECT 的用户能查视图（不需要源树 READ）
#   2) 无源树 READ 的用户查源树 → 静默空集（树模型特性）
#   3) CREATE VIEW：需要目标库 CREATE（+ 源树 READ）
#   4) ALTER VIEW：需要 ALTER；DROP VIEW：需要 DROP
#   5) REVOKE 后立即 803
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_security_${DATA_CONSENSUS}"

DB=db_tv_sec
TDB=root.tvs
VIEW=v_sec
U1=u_view
U2=u_src
PW='Tv@123456789'

treeq(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
as_user(){ printf 'set sql_dialect=%s;\n%s\n' "$1" "$2" | "$CLI" -h "${DN[0]}" -u "$3" -pw "$PW" 2>&1; }
msg(){ printf '%s\n' "$1" | grep -aE '^(Msg|Error):' | tail -1; }
rx(){ printf '%s' "$2" | grep -qE "$1"; }   # rx <regex> <text>
n_rows(){ printf '%s' "$1" | grep -ac '^|19'; }

tv_prologue "$TDB" "$DB"
tqt "create database $DB;" >/dev/null 2>&1

log "--- 0) 清理历史用户并造数据 ---"
tqt "drop user $U1;" >/dev/null 2>&1
tqt "drop user $U2;" >/dev/null 2>&1
treeq "create database $TDB;" >/dev/null 2>&1
treeq "create timeseries $TDB.d1.s1 int32;" >/dev/null 2>&1
treeq "create timeseries $TDB.d1.s2 int64;" >/dev/null 2>&1
treeq "insert into $TDB.d1(time,s1,s2) values(1,1,2);" >/dev/null 2>&1
out=$(tqt_db "$DB" "create view $VIEW (dev STRING TAG, s1 int32 field, s2 int64 field) AS $TDB.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
if rx '^\|' "$(tqt_db "$DB" "select count(*) from $VIEW;")"; then pass "root 能查视图"; else fail "root 查视图无结果"; fi

log "--- 1) 建两个受限用户 ---"
assert_contains "建用户 $U1" "$(msg "$(tqt "create user $U1 '$PW';")")" 'successfully'
assert_contains "建用户 $U2" "$(msg "$(tqt "create user $U2 '$PW';")")" 'successfully'
assert_contains "给 $U1 授 SELECT ON TABLE" "$(msg "$(tqt "grant select on table $DB.$VIEW to user $U1;")")" 'successfully'
assert_contains "给 $U2 授 READ ON 源树" "$(msg "$(treeq "grant read on $TDB.** to user $U2;")")" 'successfully'

log "--- 2) 只有视图 SELECT 的用户：能查视图、不需要源树 READ ---"
o=$(as_user table "use $DB; select * from $VIEW;" "$U1")
assert_not_contains "U1 查视图无报错" "$o" 'Exception|Access Denied'
assert_ne "U1 查到数据行（行数）" "$(n_rows "$o")" "0"
log "  $(printf '%s' "$o" | grep -a '^|19' | head -1 | cut -c1-120)"

log "--- 3) 无源树 READ：查源树是静默空集（不报错）---"
o=$(as_user tree "select * from $TDB.d1;" "$U1")
assert_not_contains "U1 查源树不报错" "$o" 'Exception|Access Denied'
assert_contains "U1 查源树为空集" "$o" 'Empty set'

log "--- 4) CREATE VIEW：U1 无目标库 CREATE → 803；U2 有源 READ 但无 CREATE → 803 ---"
o=$(msg "$(as_user table "use $DB; create view v_other (dev STRING TAG) AS $TDB.**;" "$U1")")
if rx '803|Access Denied|701' "$o"; then pass "U1 建视图被拒（803 需 CREATE）"; else fail "U1 建视图被拒（803 需 CREATE） :: $o"; fi
o=$(msg "$(as_user table "use $DB; create view v_by_src (dev STRING TAG) AS $TDB.**;" "$U2")")
if rx '803|Access Denied|701' "$o"; then pass "U2 建视图被拒（803 需目标库 CREATE）"; else fail "U2 建视图被拒（803 需目标库 CREATE） :: $o"; fi

log "--- 5) 给 U2 加目标库 CREATE → 建视图成功 ---"
assert_contains "授 CREATE ON DATABASE" "$(msg "$(tqt "grant create on database $DB to user $U2;")")" 'successfully'
o=$(msg "$(as_user table "use $DB; create view v_by_src2 (dev STRING TAG) AS $TDB.**;" "$U2")")
assert_contains "U2 建视图成功" "$o" 'successfully'
out=$(tqt_db "$DB" "show tables;")
assert_contains "新视图 v_by_src2 已建" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" 'v_by_src2'

log "--- 6) ALTER / DROP VIEW 需要 ALTER / DROP 权限 ---"
o=$(msg "$(as_user table "use $DB; alter view $VIEW add column s3 int32 field;" "$U1")")
if rx '803|Access Denied|701' "$o"; then pass "U1 无 ALTER → 被拒"; else fail "U1 无 ALTER → 被拒 :: $o"; fi
o=$(msg "$(as_user table "use $DB; drop view $VIEW;" "$U1")")
if rx '803|Access Denied|701' "$o"; then pass "U1 无 DROP → 被拒"; else fail "U1 无 DROP → 被拒 :: $o"; fi

log "--- 7) REVOKE 后立即 803 ---"
assert_contains "收回 SELECT" "$(msg "$(tqt "revoke select on table $DB.$VIEW from user $U1;")")" 'successfully'
o=$(msg "$(as_user table "use $DB; select * from $VIEW;" "$U1")")
if rx '803|Access Denied|701' "$o"; then pass "REVOKE 后 U1 查视图被拒"; else fail "REVOKE 后 U1 查视图被拒 :: $o"; fi

log "--- 8) 清理 ---"
tqt "drop user $U1;" >/dev/null 2>&1
tqt "drop user $U2;" >/dev/null 2>&1

log "--- 9) 收尾三件套 ---"
tv_sync_lag 60 || true
tv_replica_consistency "v_sec count" "select count(*) from $DB.$VIEW;"
tv_check_logs 0 "CN/DN 日志（含 803 预期拒绝）"
tv_case_finish
