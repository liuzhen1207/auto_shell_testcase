#!/bin/bash
# ============================================================================
# probe_zero_ratio_dataloss.sh —— 验证高优先级疑点：
#   expired_data_ratio=0.0 时"零脏数据文件"被反复 settle 重写，**是否会丢失不该丢的数据**？
#   （表模型用例 TB-05 D 相实测：同库 ttl='INF' 的表在 D 相循环后 count=0，而 A 相(ratio=1e-6)时数据完好）
#
#   两个场景都只做"观察 + 判定输出"，不做 fail_flag 门禁（诊断脚本）：
#     S1 树模型：root.zr_tree，d1 有 TTL，d2/d3 无 TTL  → 循环后 d2/d3 必须仍有数据
#     S2 表模型：库 zr_tb，t_z(ttl=小) + t_keep(ttl='INF') → 循环后 t_keep 必须仍有数据
#   输出末行给出 DATA_LOSS / NO_DATA_LOSS 结论，便于直接引用。
#
# 用法： bash tools/probe_zero_ratio_dataloss.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "probe_zero_ratio_dataloss"

TTL_MS=${ZR_TTL_MS:-30000}
WAIT=$(( TTL_MS/1000 + 25 ))
LOOP_OBSERVE=${ZR_OBSERVE_SEC:-60}      # 观察反复重写的时长
INF=9223372036854775807
DT=root.zr_tree
TB=zr_tb
tq(){ sql_lines_table "use $TB;" "$@"; }
loss=0

log "--- 集群准备（max_expired_time=INF, expired_data_ratio=0.0, ttl_check_interval=$TTL_CHECK_INTERVAL_MS） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=0.0 ttl_cluster_prepare

log "--- S1 树模型：d1 有 TTL($TTL_MS ms)，d2/d3 无 TTL ---"
sq "create database $DT;" >/dev/null
for d in d1 d2 d3; do sq "create timeseries $DT.$d.s1 with datatype=int64;" >/dev/null; done
sq "set ttl to $DT.d1 $TTL_MS;" >/dev/null
for d in d1 d2 d3; do sq "insert into $DT.$d(time,s1) values($(now_ms), 1);" >/dev/null; done
ensure_closed "$DT" 3 25 || warn "S1 有 DN 未落盘"
log "  S1 初始：TsFile=$(tsfile_counts_all "$DT")，d1/d2/d3 计数=$(scalar "$(sq "select count(*) from $DT.d1;")")/$(scalar "$(sq "select count(*) from $DT.d2;")")/$(scalar "$(sq "select count(*) from $DT.d3;")")"
sleep "$WAIT"
b=$(sum_over_db settle_task_for_db "$DT"); bgen=$(tsfile_gen_max "$DT")
sleep "$LOOP_OBSERVE"
a=$(sum_over_db settle_task_for_db "$DT"); agen=$(tsfile_gen_max "$DT")
c1=$(scalar "$(sq "select count(*) from $DT.d1;")"); c1=${c1:-0}
c2=$(scalar "$(sq "select count(*) from $DT.d2;")"); c2=${c2:-0}
c3=$(scalar "$(sq "select count(*) from $DT.d3;")"); c3=${c3:-0}
log "  S1 循环观察 ${LOOP_OBSERVE}s：settle $b->$a（+$((a-b))），文件代 $bgen->$agen（+$((agen-bgen))），TsFile=$(tsfile_counts_all "$DT")"
log "  S1 循环后计数：d1(有过期TTL)=$c1（期望 0）d2=$c2（期望 1）d3=$c3（期望 1）"
[ "$c2" != "1" ] || [ "$c3" != "1" ] && { loss=1; log "  >>> S1 疑似**数据丢失/不可见**：无 TTL 的设备 d2/d3 数据不在（$c2/$c3）"; }
for h in "${DN[@]}"; do log "  S1 $h [TTL]: $(ttl_last_line_for_db "$h" "$DT" | tr '\n' ' ' | cut -c1-170)"; done

log "--- S2 表模型：t_z(ttl=$TTL_MS) + t_keep(ttl='INF') 同库 ---"
out=$(sql_lines_table "create database $TB;"); log "  建库: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"
out=$(tq "create table t_z (dev string tag, v double field) with (ttl=$TTL_MS);" \
         "create table t_keep (dev string tag, v double field) with (ttl='INF');"); log "  建表: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
out=$(tq "insert into t_z (time, dev, v) values ($(now_ms), 'd1', 1);" \
         "insert into t_z (time, dev, v) values ($(now_ms), 'd2', 2);" \
         "insert into t_keep (time, dev, v) values ($(now_ms), 'k1', 9);"); log "  写入: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
ensure_closed "$TB" 3 25 || warn "S2 有 DN 未落盘"
tbz=$(scalar "$(sql_lines_table "select count(*) from $TB.t_z;")")
tbk=$(scalar "$(sql_lines_table "select count(*) from $TB.t_keep;")")
log "  S2 初始：t_z=$tbz（期望 2） t_keep=$tbk（期望 1），TsFile=$(tsfile_counts_all "$TB")"
sleep "$WAIT"
b2=$(sum_over_db settle_task_for_db "$TB"); bgen2=$(tsfile_gen_max "$TB")
sleep "$LOOP_OBSERVE"
a2=$(sum_over_db settle_task_for_db "$TB"); agen2=$(tsfile_gen_max "$TB")
tz=$(scalar "$(sql_lines_table "select count(*) from $TB.t_z;")"); tz=${tz:-0}
tk=$(scalar "$(sql_lines_table "select count(*) from $TB.t_keep;")"); tk=${tk:-0}
log "  S2 循环观察 ${LOOP_OBSERVE}s：settle $b2->$a2（+$((a2-b2))），文件代 $bgen2->$agen2（+$((agen2-bgen2))），TsFile=$(tsfile_counts_all "$TB")"
log "  S2 循环后计数：t_z=$tz（期望 0，已过期） t_keep=$tk（期望 1，ttl='INF' 永不清理）"
[ "${tk:-0}" != "1" ] && { loss=1; log "  >>> S2 疑似**数据丢失/不可见**：ttl='INF' 的表 t_keep 数据不在（$tk）"; }
out=$(tq "show tables;"); log "  S2 SHOW TABLES: $(rows_of "$out" | tr '\n' ' ')"
for h in "${DN[@]}"; do log "  S2 $h [TTL]: $(ttl_last_line_for_db "$h" "$TB" | tr '\n' ' ' | cut -c1-170)"; done

log "================ 结论 ================"
if [ "$loss" = 1 ]; then log "RESULT probe_zero_ratio_dataloss = DATA_LOSS（疑似：ratio=0.0 的 settle 循环影响/丢失了不应被清理的数据）"
else log "RESULT probe_zero_ratio_dataloss = NO_DATA_LOSS（两个场景的非过期数据都完好，仅有写放大）"; fi
log "（本脚本是诊断脚本，不写 test_result.csv 判定）"
cluster_stop
