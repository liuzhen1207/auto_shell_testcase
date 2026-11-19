#!/bin/bash
# 只探测"树转表视图"的正确建视图语法 + 改列类型
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_view"
DBV=dt3v
BASEDB=root.dt3src
BASE=$(( ($(date +%s) - 3600) * 1000 ))
show(){ local l=$1 s=$2; printf '  [%s] %s\n' "$l" "$(printf '%s' "$s" | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-180)"; }
sqt "create database $DBV;" >/dev/null 2>&1
sq "create database $BASEDB;" >/dev/null 2>&1
sq "create timeseries $BASEDB.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "create timeseries $BASEDB.d1.s2 with datatype=DOUBLE, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $BASEDB.d1(time,s1,s2) values ($(( BASE + 100 )),7,1.5),($(( BASE + 110 )),8,2.5);" >/dev/null
sq "flush;" >/dev/null; sleep 5
echo "=== 1) 尝试各种 CREATE VIEW 写法 ==="
show "A: (s1 FIELD) AS root.path"    "$(sqt "create view $DBV.v1 (s1 FIELD) as $BASEDB.d1.s1;" 2>&1)"
show "B: (s1 FIELD) AS 'path'"       "$(sqt "create view $DBV.v2 (s1 FIELD) as '$BASEDB.d1.s1';" 2>&1)"
show "C: (time, s1 FIELD) AS path"   "$(sqt "create view $DBV.v3 (time, s1 FIELD) as $BASEDB.d1.s1;" 2>&1)"
show "D: (s1 FIELD FROM s1) AS dev"  "$(sqt "create view $DBV.v4 (s1 INT32 FIELD FROM s1) as $BASEDB.d1;" 2>&1)"
show "E: (s1 FIELD FROM s1) AS star" "$(sqt "create view $DBV.v5 (s1 INT32 FIELD FROM s1) as $BASEDB.d1.**;" 2>&1)"
echo "  视图列表: $(sqt "show views from $DBV;" 2>&1 | grep -E '^\|' | tail -5 | tr '\n' ' ' | cut -c1-200)"
echo "=== 2) 改视图列类型（对已建成的视图）==="
for v in v1 v2 v3 v4 v5; do
  q=$(sqt "select * from $DBV.$v;" 2>&1 | grep -E '^\|' | tail -2 | tr '\n' ' ' | cut -c1-100)
  show "select $v" "$q"
  show "alter $v set DOUBLE" "$(sqt "alter view $DBV.$v alter column s1 set data type DOUBLE;" 2>&1)"
done
echo "=== 3) 若 v1 可用：改后查询 + 写回底层 + 合并后视图读数 ==="
show "v1 after alter" "$(sqt "select * from $DBV.v1;" 2>&1 | grep -E '^\|' | tail -3 | tr '\n' ' ' | cut -c1-120)"
show "desc v1" "$(sqt "desc $DBV.v1;" 2>&1 | grep -E '^\|' | tail -4 | tr '\n' ' ' | cut -c1-160)"
show "alter TAG column" "$(sqt "alter view $DBV.v1 alter column time set data type INT64;" 2>&1)"
echo "### 视图探测结束 $(date '+%F %T')"
