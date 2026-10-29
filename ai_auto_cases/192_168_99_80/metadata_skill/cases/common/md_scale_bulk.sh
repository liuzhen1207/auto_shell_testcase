#!/bin/bash
# ============================================================================
# MD-S01 元数据规模：量级上去以后 SHOW / COUNT / DESC / information_schema 还对不对
#
# 覆盖（规模取自 conf/env.conf：MD_BULK_SERIES=2000、MD_BULK_TABLES=200）：
#   树模型：ALIGNED 批量建时序（批量语句）→ COUNT/SHOW TIMESERIES、COUNT/SHOW DEVICES、
#           COUNT NODES LEVEL=2/3、SHOW TIMESERIES 分页（LIMIT/OFFSET）、单设备精确查询，
#           全部必须与"理论值"逐一对齐；同时记录各查询耗时
#   表模型：会话内批量建表 → SHOW TABLES / information_schema.tables / DESC / SHOW CREATE，
#           行数必须等于建表数
#
# 为什么要单列一条：小规模下 SHOW/COUNT 走的是简单路径，规模上去后容易踩
#   * 分页/截断（只返回前 N 条却不报错）
#   * COUNT 与 SHOW 行数不一致
#   * 跨 level 的计数口径漂移
# 这条用例就是把这些"只在量级上才暴露"的问题钉住。
#
# 版本：v20121rc5_1003_aaf460d（2.0.12.1 RC5）
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_s01"
TDB="${MD_PREFIX}_s01"
N_SER="${MD_BULK_SERIES:-2000}"      # 时序总数
N_TAB="${MD_BULK_TABLES:-200}"       # 表总数
M_PER_DEV=10                          # 每个设备的测量数
N_DEV=$(( N_SER / M_PER_DEV ))        # 设备数
md_case_init "md_scale_bulk"
md_cluster_prepare

log "--- 规模：时序=$N_SER（设备 $N_DEV × $M_PER_DEV 测量），表=$N_TAB ---"
drop_tree_db "$DB"
drop_table_dbs "$TDB"

# ---------------------------------------------------------------------------
log "=== 1) 树模型：批量建 $N_SER 条时序 ==="
stmts="CREATE DATABASE $DB;"
i=0
while [ "$i" -lt "$N_DEV" ]; do
  meas=""
  j=1
  while [ "$j" -le "$M_PER_DEV" ]; do
    [ -n "$meas" ] && meas="$meas, "
    meas="${meas}s${j} INT32"
    j=$((j+1))
  done
  stmts="$stmts
CREATE ALIGNED TIMESERIES $DB.d${i}(${meas});"
  i=$((i+1))
done
t0=$(date +%s)
out=$(printf '%s\n' "$stmts" | session_tree)
t1=$(date +%s)
batch_err=$(printf '%s\n' "$out" | grep -ciE 'Exception|^Error:' || true)
assert_eq "批量建库建时序无报错" "${batch_err:-0}" "0"
log "  建 $N_SER 条时序（$N_DEV 条语句）耗时 $((t1-t0))s"

log "=== 2) COUNT / SHOW TIMESERIES 必须等于 $N_SER ==="
t0=$(date +%s); c_ts=$(scalar "$(sq "COUNT TIMESERIES $DB.**;")"); t1=$(date +%s)
show_ts=$(sq "SHOW TIMESERIES $DB.**;")
rows_ts=$(md_count "$(md_rows "$show_ts")")
log "  COUNT TIMESERIES=$c_ts (${t1}s-${t0}s=$((t1-t0))s)  SHOW TIMESERIES 行数=$rows_ts"
assert_eq "COUNT TIMESERIES == $N_SER" "$c_ts" "$N_SER"
assert_eq "SHOW TIMESERIES 行数 == $N_SER" "$rows_ts" "$N_SER"

log "=== 3) COUNT / SHOW DEVICES、分层计数 ==="
show_dev=$(sq "SHOW DEVICES $DB.**;")
rows_dev=$(md_count "$(md_rows "$show_dev")")
c_dev=$(scalar "$(sq "COUNT DEVICES $DB.**;")")
log "  COUNT DEVICES=$c_dev  SHOW DEVICES 行数=$rows_dev"
assert_eq "COUNT DEVICES == $N_DEV" "$c_dev" "$N_DEV"
assert_eq "SHOW DEVICES 行数 == $N_DEV" "$rows_dev" "$N_DEV"
assert_eq "COUNT NODES LEVEL=2 == 设备数" "$(scalar "$(sq "COUNT NODES $DB.** LEVEL=2;")")" "$N_DEV"
assert_eq "COUNT NODES LEVEL=3 == 时序数" "$(scalar "$(sq "COUNT NODES $DB.** LEVEL=3;")")" "$N_SER"
assert_eq "COUNT TIMESERIES GROUP BY LEVEL=2 的行数 == 设备数" \
  "$(md_count "$(md_rows "$(sq "COUNT TIMESERIES $DB.** GROUP BY LEVEL=2;")")")" "$N_DEV"

log "=== 4) 规模下的取样：首/尾设备精确查询 + 分页 ==="
assert_eq "首设备 d0 有 $M_PER_DEV 条时序" "$(scalar "$(sq "COUNT TIMESERIES $DB.d0.**;")")" "$M_PER_DEV"
assert_eq "尾设备 d$((N_DEV-1)) 有 $M_PER_DEV 条时序" "$(scalar "$(sq "COUNT TIMESERIES $DB.d$((N_DEV-1)).**;")")" "$M_PER_DEV"
lim=$(md_count "$(md_rows "$(sq "SHOW TIMESERIES $DB.** LIMIT 100;")")")
assert_eq "SHOW TIMESERIES LIMIT 100 返回 100 行" "$lim" "100"
off=$(md_count "$(md_rows "$(sq "SHOW TIMESERIES $DB.** LIMIT 100 OFFSET 100;")")")
assert_eq "LIMIT 100 OFFSET 100 返回 100 行（未被截断）" "$off" "100"

log "=== 5) 表模型：批量建 $N_TAB 张表 ==="
tstmts="CREATE DATABASE $TDB;"
i=0
while [ "$i" -lt "$N_TAB" ]; do
  tstmts="$tstmts;;CREATE TABLE $TDB.t${i} (time TIMESTAMP TIME, dev STRING TAG, m1 INT32 FIELD);"
  i=$((i+1))
done
t0=$(date +%s)
tout=$(sql_on "$QDN" tblsess "$tstmts")
t1=$(date +%s)
terr=$(printf '%s\n' "$tout" | grep -ciE 'Exception|^Error:' || true)
assert_eq "批量建表无报错" "${terr:-0}" "0"
log "  建 $N_TAB 张表耗时 $((t1-t0))s"

log "=== 6) SHOW TABLES / information_schema.tables 行数必须等于 $N_TAB ==="
tabs=$(md_names "$(sqt "SHOW TABLES FROM $TDB;")")
assert_eq "SHOW TABLES 行数 == $N_TAB" "$(md_count "$tabs")" "$N_TAB"
assert_set_has "SHOW TABLES 含 t0" "$tabs" "t0"
assert_set_has "SHOW TABLES 含 t$((N_TAB-1))" "$tabs" "t$((N_TAB-1))"
isc=$(sqt "SELECT * FROM information_schema.tables;")
db_rows=$(printf '%s\n' "$isc" | table_rows | grep -c "$TDB" || true)
assert_ge "information_schema.tables 中本库表数 ≥ $N_TAB" "${db_rows:-0}" "$N_TAB"

log "=== 7) 规模下单表元数据仍然准确 ==="
d1=$(sqt "DESC $TDB.t0;")
assert_eq "DESC t0 列数 3" "$(md_count "$(md_rows "$d1")")" "3"
scv=$(sqt "SHOW CREATE TABLE $TDB.t$((N_TAB-1));")
assert_contains "SHOW CREATE TABLE 末张表可读" "$scv" 'CREATE TABLE'

log "--- 清理（$N_SER 条时序 + $N_TAB 张表） ---"
t0=$(date +%s)
drop_tree_db "$DB"
t1=$(date +%s)
drop_table_dbs "$TDB"
assert_set_lacks "删库后 SHOW DATABASES 不含 $DB" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB"
assert_set_lacks "删库后 SHOW DATABASES 不含 $TDB" "$(md_names "$(sqt 'SHOW DATABASES;')")" "$TDB"
log "  删库耗时 $((t1-t0))s"

md_case_finish tree 'SHOW DATABASES;'
