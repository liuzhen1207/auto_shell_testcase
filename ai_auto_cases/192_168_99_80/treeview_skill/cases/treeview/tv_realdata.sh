#!/bin/bash
# ============================================================================
# TV-06 真实数据集（树模型 TsFile → 树转表视图）
#   数据：/tmp/treeview/tsfile（由 assets/load_dataset.sh 解压+分发+load）
#   视图：db.real_<n>(sensor_id STRING TAG, value float FIELD) AS <前缀>.AA5.**
#   断言：创建成功 / 行数与树模型一致 / 聚合一致 / 视图只读 / 副本一致 / 日志干净
#   数据缺失时：WARN 跳过（不算 FAIL）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_realdata_${DATA_CONSENSUS}"

DB=db_tv_real
TREE=${TV_DATA_DB:-root.reactor}
DEV_PREFIX=${TV_DATA_DEV:-$TREE.system1.techSystem1.DX.HYH_W3.AA5}
VIEW=real_aa5

tree_q(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }

log "--- 0) prologue（会清理 data）后再检查/装载真实数据 ---"
tv_prologue_keep "$DB"
# ---- 前置自保证（2026-11-13）：**必须放在 prologue 之后** ----
# prologue 会 rm -rf data（各用例都会），所以数据只有在 prologue 之后装载才留得住；
# 另外 `load` 是异步的：设备元数据先出现、数据点稍后才可查，建视图前要等数据点。
log "--- 0) 检查真实数据是否已装载 ---"
have=$(tree_q "show devices $DEV_PREFIX.**;" | table_rows | wc -l | tr -d ' ')
# 前置自保证（2026-11-13）：整套跑时各用例的 prologue 会清 data，真实数据会被抹掉。
# 这里在缺数据时自动装载一次（load_dataset.sh 幂等：解压→分发→逐 DN load→等设备出现）。
if [ "${have:-0}" -eq 0 ]; then
  log "  真实数据缺失 ⇒ 自动装载（assets/load_dataset.sh）"
  if bash "$HERE/../../assets/load_dataset.sh" >>"$OUT" 2>&1; then
    have=$(tree_q "show devices $DEV_PREFIX.**;" | table_rows | wc -l | tr -d ' ')
    log "  装载后设备数=${have:-0}"
  else
    warn "  assets/load_dataset.sh 返回非 0，见 $OUT"
  fi
fi
if [ "${have:-0}" -eq 0 ]; then
  warn "真实数据未装载（$DEV_PREFIX 下没有设备）⇒ 跳过本用例（先跑 assets/load_dataset.sh）"
  tv_case_finish
  exit 0
fi
log "  $DEV_PREFIX 下设备数=$have"
# 等数据点真正可查（2026-11-13）：`load` 是异步的，设备元数据先出现、数据点稍后才可见；
# 实测自动装载后立刻建视图会查到 0 行（此前单独跑能过，是因为数据已在前一轮 load 完并 flush 过）。
wait_dev=$(tree_q "show devices $DEV_PREFIX.** limit 1;" | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}')
if [ -n "${wait_dev:-}" ]; then
  pts=0
  for i in $(seq 1 60); do
    pts=$(tree_q "select count(*) from $wait_dev;" | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}')
    pts=${pts:-0}
    [ "$pts" -gt 0 ] 2>/dev/null && break
    sleep 30
  done
  log "  等数据点可查：$wait_dev count=$pts（等待 $((i*30))s，最多 30min）"
  [ "${pts:-0}" -gt 0 ] 2>/dev/null || warn "  数据点仍不可查（count=${pts:-0}，已等 $((i*30))s）；425MB load 是异步的，可能还需更久"
fi

tqt "create database $DB;" >/dev/null 2>&1
sleep 1

log "--- 1) 建树转表视图（取用户示例口径：1 个 TAG + 1 个 FIELD）---"
out=$(tqt_db "$DB" "create view $VIEW (sensor_id STRING TAG, value float field) AS $DEV_PREFIX.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
out=$(tqt_db "$DB" "desc $VIEW;")
assert_contains "视图含 sensor_id/ value 列" "$out" 'sensor_id'
assert_contains "视图含 value 列" "$out" 'value'

log "--- 2) 取一个传感器做精确对照（避免全表聚合触发 719 内存上限）---"
SENSOR=$(printf 'set sql_dialect=tree;\nshow devices %s.** limit 1;\n' "$DEV_PREFIX" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 \
  | grep -a '^|' | sed -n '2p' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | awk -F'.' '{print $NF}')
log "  传感器（sensor_id）=$SENSOR  设备=$DEV_PREFIX.$SENSOR"
[ -z "$SENSOR" ] && { fail "取不到传感器名"; tv_case_finish; exit 1; }

T0='2024-11-21T08:00:00'
T1='2024-11-21T09:00:00'
v_c=$(tcol "$(tqt_db "$DB" "select count(*) from $VIEW where sensor_id='$SENSOR' and time >= $T0 and time < $T1;")" 1)
t_c=$(tcol "$(tree_q "select count(*) from $DEV_PREFIX.$SENSOR where time >= $T0 and time < $T1;")" 1)
log "  时间窗 [$T0, $T1)：视图=$v_c 树=$t_c"
assert_num_eq "该传感器时间窗内行数：视图与树一致" "$v_c" "$t_c"
assert_ne "视图确实有数据（>0）" "$v_c" "0"

v_avg=$(tcol "$(tqt_db "$DB" "select round(avg(value),4) from $VIEW where sensor_id='$SENSOR' and time >= $T0 and time < $T1;")" 1)
t_avg=$(tcol "$(tree_q "select round(avg(value),4) from $DEV_PREFIX.$SENSOR where time >= $T0 and time < $T1;")" 1)
log "  时间窗内 avg：视图=$v_avg 树=$t_avg"
assert_num_eq "该传感器时间窗内 avg：视图与树一致" "$v_avg" "$t_avg"

log "--- 3) 单传感器最近 3 行 ---"
out=$(tqt_db "$DB" "select time, sensor_id, value from $VIEW where sensor_id='$SENSOR' order by time desc limit 3;")
assert_not_contains "单传感器 order by/limit 无报错" "$out" 'Exception|ERROR'
if printf '%s' "$out" | grep -q '^|'; then pass "查询结果含数据行"; else fail "查询结果不含数据行 :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fi
log "  $(printf '%s' "$out" | grep -a '^|' | tail -3 | tr '\n' ' ' | cut -c1-200)"

log "--- 4) 分组/过滤 ---"
out=$(tqt_db "$DB" "select count(*) from $VIEW where time >= $T0 and time < $T1 group by sensor_id limit 3;")
assert_not_contains "group by sensor_id 无报错" "$out" 'Exception|ERROR'

log "--- 5) 视图只读 ---"
out=$(tqt_db "$DB" "insert into $VIEW(time,sensor_id,value) values (1,'x',1.0);")
assert_not_contains "通过视图写入应被拒绝" "$(last_msg "$out")" 'successfully'

log "--- 6) 收尾三件套 ---"
tv_sync_lag 120 || true
tv_replica_consistency "视图 count" "select count(*) from $DB.$VIEW;"
tv_check_logs 0 "CN/DN 日志"
tv_case_finish
