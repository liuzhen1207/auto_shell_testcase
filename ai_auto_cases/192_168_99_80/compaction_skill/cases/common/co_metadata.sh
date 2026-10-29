#!/bin/bash
# ============================================================================
# CO-06 冒烟：元数据变更后合并（删时序/删设备/删表/删库重建）
#   目的：schema 变化（DELETE TIMESERIES / DELETE DEVICES / DROP TABLE / DROP DATABASE 后重建）
#         之后合并仍能正常进行、且不会出现 CompactionTableSchemaNotMatchException 等异常。
#   判据：
#     1) 元数据删除生效（被删对象查不到）
#     2) 继续写入 + 合并完成（finishes 增长、文件数下降）
#     3) 被删对象仍然不存在（合并不得"复活"元数据）、其余对象数据指纹不变
#     4) 删库重建后新库可写可合并
#     5) 收尾三件套（日志扫描覆盖 CompactionTableSchemaNotMatchException / NPE / 越界 / OOM / overlap）
# 用法： bash co_metadata.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_metadata_${DATA_CONSENSUS}"

DBT=root.cometa
DBT2=root.cometa2
DBB=cometatb
DEVS=${CO_DEVS:-4}
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-120}

log "--- 集群准备（合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

# ------------------------------------------------------------------ 树模型：删时序
log "--- 树模型 $DBT：写入 → DELETE TIMESERIES d2 → 再写 → 合并 ---"
cmp_make_tree_db "$DBT" "$DEVS"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
cmp_write_tree_batch "$DBT" "$DEVS" "$ROWS" 1 "$BASE"
ensure_closed "$DBT" 3 25 || warn "$DBT 未全部落盘"
BEFORE_TS=$(sq "show timeseries $DBT.**;" | table_rows | wc -l | tr -d ' ')
sq "delete timeseries $DBT.d2.**;" >/dev/null
sq "flush;" >/dev/null
sleep 5
AFTER_TS=$(sq "show timeseries $DBT.**;" | table_rows | wc -l | tr -d ' ')
log "  SHOW TIMESERIES 行数：$BEFORE_TS → $AFTER_TS"
[ "${AFTER_TS:-0}" -lt "${BEFORE_TS:-0}" ] && pass "DELETE TIMESERIES 生效（元数据减少）" || fail "DELETE TIMESERIES 未生效"
assert_not_contains "被删时序 $DBT.d2 不应再出现在 SHOW TIMESERIES" "$(sq "show timeseries $DBT.**;")" "$DBT.d2"
# 再写一批并合并。注意：**不能整批重写 d1..dN**——插入会给被删的 d2 自动重建元数据，
# 后面"合并后 d2 仍不存在"的断言就永远不成立（这是本用例第一版踩到的坑）。
for d in $(seq 1 "$DEVS"); do
  [ "$d" = "2" ] && continue
  _vals=""
  for ((k=1;k<=ROWS;k++)); do
    _vals="$_vals($(( BASE + 2000000 + k * 10 )),$((k+5))),"
    if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $DBT.d$d(time,s1) values ${_vals%,};" >/dev/null; _vals=""; fi
  done
  [ -n "$_vals" ] && sq "insert into $DBT.d$d(time,s1) values ${_vals%,};" >/dev/null
done
sq "flush;" >/dev/null
ensure_closed "$DBT" 3 25 || warn "$DBT 第 2 批未全部落盘"
# 指纹必须在本相**全部写入之后**采集：第一版在补写之前就取了 d1 指纹，
# 补写又给 d1 加了新行 ⇒ 合并后比对必然不一致（假 FAIL）。
fpd0=$(cmp_fingerprint tree "select s1 from $DBT.d1 order by time")
ts0=$(cmp_all_sum "$DBT"); fin0=$(cmp_inner_finish "$DBT")
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DBT" "$fin0" "$ts0" "$WIN"); then pass "删元数据后合并正常：$RES"; else fail "删元数据后合并未推进（$RES）"; fi
assert_not_contains "合并后 $DBT.d2 仍不存在" "$(sq "show timeseries $DBT.**;")" "$DBT.d2"
cmp_assert_same "其余设备数据指纹不变（$DBT.d1）" "$fpd0" "$(cmp_fingerprint tree "select s1 from $DBT.d1 order by time")"

# ------------------------------------------------------------------ 树模型：删库重建
log "--- 树模型 $DBT2：写入 → DROP DATABASE → 重建 → 写 → 合并 ---"
# 上一相已把合并热开：本相写入前先关掉，否则数据在写入期间就被合并完，基线之后不再推进
cmp_compaction_off
cmp_make_tree_db "$DBT2" 2
cmp_write_tree_batch "$DBT2" 2 "$ROWS" 1 "$BASE"
ensure_closed "$DBT2" 3 25 || warn "$DBT2 未全部落盘"
sq "drop database $DBT2;" >/dev/null
sleep 5
assert_contains "DROP DATABASE 后查库报错/为空" "$(sq "select count(s1) from $DBT2.**;")" 'IoTDBSQLException|Empty set|Msg:'
cmp_make_tree_db "$DBT2" 2
# 重建后必须写 **2 批**：只写 1 批的话每 region 只有 1 个 TsFile，inner 合并候选不足
# （candidate=2）⇒ 记完基线不会再有推进，会误判"合并未推进"
cmp_write_tree_batch "$DBT2" 2 "$ROWS" 1 "$BASE"
cmp_write_tree_batch "$DBT2" 2 "$ROWS" 2 "$(( BASE + 3000000 ))"
ensure_closed "$DBT2" 3 25 || warn "$DBT2 重建后未全部落盘"
ts0=$(cmp_all_sum "$DBT2"); fin0=$(cmp_inner_finish "$DBT2")
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DBT2" "$fin0" "$ts0" "$WIN"); then pass "删库重建后合并正常：$RES"; else fail "删库重建后合并未推进（$RES）"; fi
assert_contains "重建库数据可查" "$(sq "select count(s1) from $DBT2.d1.**;")" '[0-9]'

# ------------------------------------------------------------------ 表模型：删表 + 删设备
log "--- 表模型 $DBB：建三表 → 写 → DROP TABLE t3 / DELETE DEVICES → 合并 ---"
cmp_compaction_off   # 同上：保证"写完再开合并"可复现
cmp_make_table_db "$DBB" t1 t2
sqt "create table $DBB.t3 (time TIMESTAMP TIME, dev STRING TAG, v INT64 FIELD);" | grep -q successfully && pass "建 t3 成功" || warn "建 t3 失败"
cmp_write_table_batch "$DBB" t1 "$DEVS" "$ROWS" 1 "$BASE"
cmp_write_table_batch "$DBB" t3 "$DEVS" "$ROWS" 1 "$BASE"
ensure_closed "$DBB" 3 25 || warn "$DBB 未全部落盘"
TB1=$(sqt "show tables from $DBB;" | table_rows | wc -l | tr -d ' ')
sqt "drop table $DBB.t3;" >/dev/null
sleep 5
TB2=$(sqt "show tables from $DBB;" | table_rows | wc -l | tr -d ' ')
log "  SHOW TABLES 行数：$TB1 → $TB2"
[ "${TB2:-0}" -lt "${TB1:-0}" ] && pass "DROP TABLE 生效" || fail "DROP TABLE 未生效"
# 删设备（表模型 DELETE DEVICES）
sqt "delete devices from $DBB.t1 where dev = 'd1';" >/dev/null
sqt "flush;" >/dev/null
sleep 5
# 同上：跳过已被 DELETE DEVICES 删掉的 d1，否则插入会把 d1 又建回来
for d in $(seq 1 "$DEVS"); do
  [ "$d" = "1" ] && continue
  _vals=""
  for ((k=1;k<=ROWS;k++)); do
    _vals="$_vals($(( BASE + 2000000 + k * 10 )),'d$d',$((k+5))),"
    if [ $(( k % 500 )) -eq 0 ]; then sqt "insert into $DBB.t1 (time, dev, v) values ${_vals%,};" >/dev/null; _vals=""; fi
  done
  [ -n "$_vals" ] && sqt "insert into $DBB.t1 (time, dev, v) values ${_vals%,};" >/dev/null
done
sqt "flush;" >/dev/null
ensure_closed "$DBB" 3 25 || warn "$DBB 第 2 批未全部落盘"
tts0=$(cmp_all_sum "$DBB"); tfin0=$(cmp_inner_finish "$DBB")
cmp_compaction_on true true false
if TRES=$(cmp_wait_merge "$DBB" "$tfin0" "$tts0" "$WIN"); then pass "表模型删表/删设备后合并正常：$TRES"; else fail "表模型删表/删设备后合并未推进（$TRES）"; fi
assert_not_contains "合并后 t3 仍不在 SHOW TABLES 里" "$(sqt "show tables from $DBB;")" 't3'
[ "$(sqt "select count(*) from $DBB.t1 where dev='d1';" | table_rows | head -1 | awk -F'|' '{print ($2+0)}')" = "0" ] \
  && pass "被删设备 d1 仍无数据（合并未复活）" || fail "被删设备 d1 又出现数据"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DBT.d1 order by time;" tree
cmp_case_finish "" tree ""
