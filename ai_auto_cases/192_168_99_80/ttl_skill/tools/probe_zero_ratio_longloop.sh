#!/bin/bash
# ============================================================================
# probe_zero_ratio_longloop.sh —— 确认"ratio=0.0 长时间重写循环"下非过期数据是否最终读不到
#   背景：
#     - 60s 观察的 probe_zero_ratio_dataloss → NO_DATA_LOSS（t_keep=1、d2/d3=1）
#     - 但 TB-05 D 相（循环已跑数分钟后）轮询 60s 仍读到 t_keep=0
#   本脚本在 M=INF + ratio=0.0 下持续循环 ~6 分钟，每 30s 采样一次各表/设备行数，
#   记录最小值与"首次读到 0 的时刻"，末行给 LATE_LOSS / NO_LOSS 结论。
# 用法： bash tools/probe_zero_ratio_longloop.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "probe_zero_ratio_longloop"

TTL_MS=${ZR_TTL_MS:-30000}
SAMPLES=${ZR_SAMPLES:-12}          # 采样次数
INTERVAL=${ZR_INTERVAL:-30}        # 采样间隔秒
INF=9223372036854775807
TB=zrl_tb
DT=root.zrl_tree
tq(){ sql_lines_table "use $TB;" "$@"; }

log "--- 集群准备（M=INF, ratio=0.0, ttl_check_interval=$TTL_CHECK_INTERVAL_MS） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=0.0 ttl_cluster_prepare

log "--- 造两个场景 ---"
sql_lines_table "create database $TB;" >/dev/null
tq "create table t_z (dev string tag, v double field) with (ttl=$TTL_MS);" \
   "create table t_keep (dev string tag, v double field) with (ttl='INF');" >/dev/null
tq "insert into t_z (time, dev, v) values ($(now_ms), 'd1', 1);" \
   "insert into t_z (time, dev, v) values ($(now_ms), 'd2', 2);" \
   "insert into t_keep (time, dev, v) values ($(now_ms), 'k1', 9);" >/dev/null
sq "create database $DT;" >/dev/null
for d in d1 d2 d3; do sq "create timeseries $DT.$d.s1 with datatype=int64;" >/dev/null; done
sq "set ttl to $DT.d1 $TTL_MS;" >/dev/null
for d in d1 d2 d3; do sq "insert into $DT.$d(time,s1) values($(now_ms), 1);" >/dev/null; done
ensure_closed "$TB" 3 25 || true
ensure_closed "$DT" 3 25 || true
log "  初始：t_keep=$(scalar "$(sql_lines_table "select count(*) from $TB.t_keep;")") t_z=$(scalar "$(sql_lines_table "select count(*) from $TB.t_z;")") d2=$(scalar "$(sq "select count(*) from $DT.d2;")") d3=$(scalar "$(sq "select count(*) from $DT.d3;")")"

sleep $(( TTL_MS/1000 + 20 ))      # 等过期，循环开始
b=$(sum_over_db settle_task_for_db "$TB"); bgen=$(tsfile_gen_max "$TB")
min_tk=99; min_d2=99; min_d3=99; zero_at=""
log "--- 采样 ${SAMPLES} 次 × ${INTERVAL}s（观察长时间循环下的可读性）---"
for ((i=1;i<=SAMPLES;i++)); do
  tk=$(scalar "$(sql_lines_table "select count(*) from $TB.t_keep;")"); tk=${tk:-0}
  tz=$(scalar "$(sql_lines_table "select count(*) from $TB.t_z;")");    tz=${tz:-0}
  d2=$(scalar "$(sq "select count(*) from $DT.d2;")"); d2=${d2:-0}
  d3=$(scalar "$(sq "select count(*) from $DT.d3;")"); d3=${d3:-0}
  cur=$(sum_over_db settle_task_for_db "$TB"); agen=$(tsfile_gen_max "$TB")
  log "  [$i/$SAMPLES] t_keep=$tk t_z=$tz | d2=$d2 d3=$d3 | settle=$cur(+$((cur-b))) gen=$agen(+$((agen-bgen))) TsFile(表)=$(tsfile_counts_all "$TB") TsFile(树)=$(tsfile_counts_all "$DT")"
  [ "$tk" -lt "$min_tk" ] && min_tk=$tk
  [ "$d2" -lt "$min_d2" ] && min_d2=$d2
  [ "$d3" -lt "$min_d3" ] && min_d3=$d3
  [ "$tk" = "0" ] && [ -z "$zero_at" ] && zero_at="第 $i 次采样"
  sleep "$INTERVAL"
done
log "--- 统计：t_keep 最小=$min_tk（首次读到 0：${zero_at:-无}），d2 最小=$min_d2，d3 最小=$min_d3 ---"
for h in "${DN[@]}"; do log "  $h [TTL]: $(ttl_last_line_for_db "$h" "$TB" | tr '\n' ' ' | cut -c1-170)"; done
if [ "$min_tk" -eq 0 ] || [ "$min_d2" -eq 0 ] || [ "$min_d3" -eq 0 ]; then
  log "RESULT probe_zero_ratio_longloop = LATE_EMPTY_READ（长时间循环下非过期数据出现读不到：t_keep min=$min_tk, d2 min=$min_d2, d3 min=$min_d3）——需研发确认是数据丢失还是重写期间读取不可见"
else
  log "RESULT probe_zero_ratio_longloop = NO_LOSS（长时间循环下非过期数据始终可读）"
fi
cluster_stop
