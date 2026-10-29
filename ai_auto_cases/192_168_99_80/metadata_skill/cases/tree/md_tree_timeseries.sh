#!/bin/bash
# ============================================================================
# MD-T02 树模型 TIMESERIES 元数据闭环
#
# 覆盖：
#   建时序（完整属性 / 简化 / 对齐 / TAGS+ATTRIBUTES / 压缩编码属性）
#   SHOW TIMESERIES（全量 / 路径 / 精确 / WHERE DATATYPE / WHERE TAGS / LIMIT / ORDER BY）
#   COUNT TIMESERIES（全量 / 各级 / GROUP BY LEVEL=N）、COUNT NODES LEVEL=n
#   SHOW DEVICES（全量 / 路径 / WHERE DEVICE CONTAINS / WITH DATABASE）、COUNT DEVICES
#   SHOW LATEST / SHOW INVALID TIMESERIES
#   ALTER TIMESERIES（SET DATA TYPE / RENAME TO / ADD-RENAME-DROP TAGS / UPSERT ALIAS/UPSERT TAGS /
#                     SET STORAGE_PROPERTIES / IF EXISTS）
#   SHOW CHILD PATHS / SHOW CHILD NODES
#   失败路径：重复建（503）、非法类型（701）、编码与类型不匹配（507）、CREATE ... ALIAS（507）
#
# 判据：SHOW TIMESERIES / SHOW DEVICES / COUNT 之间必须互相自洽（集合行数 = COUNT 值），
#       并且 ALTER 后 SHOW 的属性要随之变化。
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_t02"
md_case_init "md_tree_timeseries"
md_cluster_prepare

log "--- 清理历史对象 ---"
drop_tree_db "$DB"
assert_ok "建库 $DB" "$(sq "CREATE DATABASE $DB;")"

# ---------------------------------------------------------------------------
log "=== 1) 建时序的多种写法 ==="
assert_ok "完整属性建时序"   "$(sq "CREATE TIMESERIES $DB.d1.s1 WITH DATATYPE=INT32, ENCODING=RLE;")"
assert_ok "简化写法建时序"   "$(sq "CREATE TIMESERIES $DB.d1.s2 INT64;")"
assert_ok "带压缩/TEXT 属性" "$(sq "CREATE TIMESERIES $DB.d1.s3 WITH DATATYPE=TEXT, ENCODING=PLAIN, COMPRESSOR=SNAPPY;")"
assert_ok "带 TAGS+ATTRIBUTES" "$(sq "CREATE TIMESERIES $DB.d1.s4 INT32 TAGS(k1=v1) ATTRIBUTES(a1=b1);")"
assert_ok "对齐时序"         "$(sq "CREATE ALIGNED TIMESERIES $DB.d2(s1 INT32, s2 FLOAT);")"
assert_ok "第二个设备"       "$(sq "CREATE TIMESERIES $DB.d2b.s1 FLOAT;")"
# 自动建库（元数据副作用）
assert_ok "在不存在的库下建时序会自动建库" "$(sq "CREATE TIMESERIES root.${MD_PREFIX}_autodb.d1.s1 INT32;")"

log "=== 2) SHOW TIMESERIES 集合与 COUNT 自洽 ==="
ts_all=$(sq "SHOW TIMESERIES $DB.**;")
cnt_all=$(scalar "$(sq "COUNT TIMESERIES $DB.**;")")
assert_eq "COUNT TIMESERIES == SHOW TIMESERIES 行数" "$cnt_all" "$(md_count "$(md_rows "$ts_all")")"

paths=$(md_names "$ts_all")
for p in "$DB.d1.s1" "$DB.d1.s2" "$DB.d1.s3" "$DB.d1.s4" "$DB.d2.s1" "$DB.d2.s2" "$DB.d2b.s1"; do
  assert_set_has "SHOW TIMESERIES 含 $p" "$paths" "$p"
done

log "=== 3) 精确路径 / WHERE / LIMIT / ORDER BY ==="
one=$(sq "SHOW TIMESERIES $DB.d1.s1;")
assert_eq "精确查询返回 1 行" "$(md_count "$(md_rows "$one")")" "1"
assert_contains "精确查询行含 datatype=INT32" "$one" '\| *INT32 *\|'
empty_ok=$(sq "SHOW TIMESERIES $DB.nosuchdev.**;")
assert_ok "不存在的路径 SHOW TIMESERIES 不报错" "$empty_ok"
assert_eq "不存在的路径返回空集" "$(md_count "$(md_rows "$empty_ok")")" "0"

where_ok=$(sq "SHOW TIMESERIES $DB.** WHERE DATATYPE='INT32';")
assert_ok "SHOW TIMESERIES WHERE DATATYPE" "$where_ok"
assert_set_is "WHERE DATATYPE=INT32 只返回 INT32 的 3 条" "$(md_names "$where_ok")" \
  "$DB.d1.s1" "$DB.d1.s4" "$DB.d2.s1"
where_tag=$(sq "SHOW TIMESERIES $DB.** WHERE TAGS(k1)='v1';")
assert_set_is "WHERE TAGS(k1)=v1" "$(md_names "$where_tag")" "$DB.d1.s4"
lim=$(md_count "$(md_rows "$(sq "SHOW TIMESERIES $DB.** LIMIT 3;")")")
assert_eq "LIMIT 3" "$lim" "3"
assert_ok "ORDER BY TIMESERIES DESC" "$(sq "SHOW TIMESERIES $DB.** ORDER BY TIMESERIES DESC;")"

log "=== 4) 分层计数 ==="
assert_eq "COUNT TIMESERIES LEVEL 全路径" "$(scalar "$(sq "COUNT TIMESERIES $DB.**;")")" "7"
assert_eq "COUNT TIMESERIES $DB.*.*"      "$(scalar "$(sq "COUNT TIMESERIES $DB.*.*;")")" "7"
grp=$(sq "COUNT TIMESERIES $DB.** GROUP BY LEVEL=2;")
assert_contains "GROUP BY LEVEL=2 按设备分组" "$grp" "$DB\.d1"
assert_eq "COUNT NODES LEVEL=2（设备数）" "$(scalar "$(sq "COUNT NODES $DB.** LEVEL=2;")")" "3"
assert_eq "COUNT NODES LEVEL=3（序列数）" "$(scalar "$(sq "COUNT NODES $DB.** LEVEL=3;")")" "7"

log "=== 5) SHOW DEVICES / COUNT DEVICES 自洽 ==="
dev=$(sq "SHOW DEVICES $DB.**;")
assert_eq "COUNT DEVICES == SHOW DEVICES 行数" "$(scalar "$(sq "COUNT DEVICES $DB.**;")")" "$(md_count "$(md_rows "$dev")")"
devnames=$(md_names "$dev")
assert_set_has "SHOW DEVICES 含 $DB.d1"  "$devnames" "$DB.d1"
assert_set_has "SHOW DEVICES 含 $DB.d2b" "$devnames" "$DB.d2b"
assert_contains "SHOW DEVICES WITH DATABASE 多一列库名" "$(sq "SHOW DEVICES $DB.** WITH DATABASE;")" "$DB"
assert_set_is "SHOW DEVICES WHERE DEVICE CONTAINS 'd2b'" "$(md_names "$(sq "SHOW DEVICES $DB.** WHERE DEVICE CONTAINS 'd2b';")")" "$DB.d2b"

log "=== 6) SHOW CHILD PATHS / NODES ==="
childnodes=$(sq "SHOW CHILD NODES $DB;")
assert_contains "SHOW CHILD NODES $DB 含 d1"  "$childnodes" 'd1'
assert_contains "SHOW CHILD NODES $DB 含 d2b" "$childnodes" 'd2b'
assert_contains "SHOW CHILD PATHS 标注类型" "$(sq "SHOW CHILD PATHS $DB.**;")" 'TIMESERIES'

log "=== 7) ALTER TIMESERIES 后元数据必须随之变化 ==="
assert_ok "SET DATA TYPE INT64" "$(sq "ALTER TIMESERIES $DB.d1.s2 SET DATA TYPE DOUBLE;")"
assert_contains "SHOW 中 d1.s2 变为 DOUBLE" "$(sq "SHOW TIMESERIES $DB.d1.s2;")" '\| *DOUBLE *\|'
assert_ok "ADD TAGS" "$(sq "ALTER TIMESERIES $DB.d1.s1 ADD TAGS t1=v1;")"
assert_contains "SHOW 中出现 tag t1" "$(sq "SHOW TIMESERIES $DB.d1.s1;")" 't1'
assert_ok "ADD ATTRIBUTES" "$(sq "ALTER TIMESERIES $DB.d1.s1 ADD ATTRIBUTES a9=b9;")"
assert_ok "RENAME tag t1->t2" "$(sq "ALTER TIMESERIES $DB.d1.s1 RENAME t1 TO t2;")"
assert_contains "SHOW 中 tag 已改名 t2" "$(sq "SHOW TIMESERIES $DB.d1.s1;")" 't2'
assert_ok "DROP tag t2" "$(sq "ALTER TIMESERIES $DB.d1.s1 DROP t2;")"
assert_not_contains "SHOW 中不再有 t2" "$(sq "SHOW TIMESERIES $DB.d1.s1;")" 't2'
assert_ok "UPSERT ALIAS" "$(sq "ALTER TIMESERIES $DB.d1.s1 UPSERT ALIAS=al1;")"
assert_contains "SHOW 中出现 alias al1" "$(sq "SHOW TIMESERIES $DB.d1.s1;")" 'al1'
assert_ok "UPSERT TAGS+ATTRIBUTES" "$(sq "ALTER TIMESERIES $DB.d1.s1 UPSERT TAGS(k3=v3) ATTRIBUTES(a3=b3);")"
assert_ok "SET STORAGE_PROPERTIES" "$(sq "ALTER TIMESERIES $DB.d1.s1 SET STORAGE_PROPERTIES ENCODING=TS_2DIFF;")"
assert_ok "ALTER TIMESERIES IF EXISTS 不存在的路径" "$(sq "ALTER TIMESERIES IF EXISTS $DB.d1.s9 SET STORAGE_PROPERTIES ENCODING=RLE;")"

log "=== 8) RENAME TO：元数据必须迁移，且 SHOW INVALID 能看到死路径 ==="
assert_ok "RENAME TO 新路径" "$(sq "ALTER TIMESERIES $DB.d1.s3 RENAME TO $DB.d1.s3r;")"
paths=$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")
assert_set_has   "新路径出现在 SHOW TIMESERIES"   "$paths" "$DB.d1.s3r"
assert_set_lacks "旧路径不再出现在 SHOW TIMESERIES" "$paths" "$DB.d1.s3"
invalid=$(sq "SHOW INVALID TIMESERIES $DB.**;")
log "  SHOW INVALID TIMESERIES 输出行数=$(md_count "$(md_rows "$invalid")")"
assert_contains "SHOW INVALID 记录了被改名/失效的旧路径" "$invalid" "$DB\.d1\.s3"

log "=== 9) 失败路径 ==="
assert_error "重复建时序（503）" "$(sq "CREATE TIMESERIES $DB.d1.s1 INT32;")" '503'
assert_error "非法数据类型（701）" "$(sq "CREATE TIMESERIES $DB.d9.s1 WITH DATATYPE=NOTATYPE;")" '701'
assert_error "编码与类型不匹配 TEXT+RLE（507）" "$(sq "CREATE TIMESERIES $DB.d9.s2 WITH DATATYPE=TEXT, ENCODING=RLE;")" '507'
assert_error "CREATE TIMESERIES ... ALIAS 非法属性（507）" "$(sq "CREATE TIMESERIES $DB.d9.s3 INT32 ALIAS=al9;")" '507'
assert_error "CREATE TIMESERIES IF NOT EXISTS（RC5 不支持，700）" "$(sq "CREATE TIMESERIES IF NOT EXISTS $DB.d1.s1 INT32;")" '700'
assert_error "一次建多条时序（RC5 不支持，700）" "$(sq "CREATE TIMESERIES $DB.d9.s1 INT32, $DB.d9.s2 INT64;")" '700'
assert_error "DROP 不存在的时序（508）" "$(sq "DROP TIMESERIES $DB.d9.s9;")" '508'

log "=== 10) DROP / DELETE 后元数据消失 ==="
assert_ok "DELETE TIMESERIES" "$(sq "DELETE TIMESERIES $DB.d2.s2;")"
assert_set_lacks "DELETE 后 SHOW 中不再有 d2.s2" "$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")" "$DB.d2.s2"
assert_ok "DROP 整个设备" "$(sq "DROP TIMESERIES $DB.d2b.**;")"
devnames=$(md_names "$(sq "SHOW DEVICES $DB.**;")")
assert_set_lacks "DROP 设备后 SHOW DEVICES 不再有 d2b" "$devnames" "$DB.d2b"
assert_set_lacks "DROP 设备后 SHOW TIMESERIES 不再有 d2b.s1" "$(md_names "$(sq "SHOW TIMESERIES $DB.**;")")" "$DB.d2b.s1"

log "--- 清理 ---"
drop_tree_db "$DB"
q_tree "DROP DATABASE root.${MD_PREFIX}_autodb"

md_case_finish tree "SHOW TIMESERIES $DB.**;"
