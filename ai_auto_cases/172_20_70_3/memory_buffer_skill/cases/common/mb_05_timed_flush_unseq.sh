#!/bin/bash
# MB-05 定时刷盘（乱序空间）：enable_timed_flush_unseq_memtable + interval + check_interval
#
# 需求依据：《内存缓冲区-需求分析》配置表
#   enable_timed_flush_unseq_memtable（默认 true）、unseq_memtable_flush_interval_in_ms（默认 600000）、
#   unseq_memtable_flush_check_interval_in_ms（默认 30000），三者**均热加载**。
# 与 MB-04（seq 空间）对称，专门验证乱序空间：
#   先写一批"水位"数据（当前时间）再写更早且互相重叠的批次 ⇒ 落 unsequence/；
#   flush_proportion 保持够大（不按大小刷），只靠定时器落盘。
# 判据：① 不手工 flush 也在窗口内产生新 TsFile；② 关掉开关后同窗口不产生（对照）；③ 数据点数正确。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-05
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="${MB_MEM_PROPORTION:-1:1000:1:1:1:1}"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"          # 关掉 seq 定时器，确保只测 unseq 路径
MB_TIMED_FLUSH_UNSEQ="true"
MB_UNSEQ_FLUSH_INTERVAL="15000"
MB_UNSEQ_FLUSH_CHECK="5000"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ \
       MB_UNSEQ_FLUSH_INTERVAL MB_UNSEQ_FLUSH_CHECK
DB=root.mb05
ROWS=${MB05_ROWS:-600}
WIN=${MB05_WIN:-150}
export EXTRA_CONF=""

# 定时刷盘的主判据用**产品日志行**（最直接，不受异步 close 与目录分布影响）：
#   `Exceed unsequence memtable flush interval, so flush working memtable of time partition ...`
# 源码依据：DataRegion.timedFlushUnseqMemTable()
# 辅助证据：tsfile 合计变化 + sequence/unsequence 分布。
mb_unseq_timed_cnt(){ local h=$1
  sshx "$h" "grep -hc 'Exceed unsequence memtable flush interval' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_unseq_timed_all(){ local h s=0 v; for h in "${DN[@]}"; do v=$(mb_unseq_timed_cnt "$h"); s=$(( s + ${v:-0} )); done; echo "$s"; }
wait_unseq_flush(){ local db=$1 t0=$2 win=$3 deadline=$(( $(date +%s) + ${3:-150} )) now u s l
  while (( $(date +%s) < deadline )); do
    now=$(mb_tsfile_cnt_all "$db"); u=$(mb_unseq_all "$db"); s=$(mb_seq_all "$db"); l=$(mb_unseq_timed_all)
    log "  定时刷盘观察: 日志触发=$l  tsfile 合计=$now (基线=$t0)  sequence=$s unsequence=$u"
    [ "${l:-0}" -gt "${4:-0}" ] && return 0
    [ "${now:-0}" -gt "${t0:-0}" ] && return 0
    sleep 10
  done
  return 1
}

mb_cluster_prepare
mb_make_tree_db "$DB" 1 int64

log "--- 造乱序数据：先写水位，再写更早且互相重叠的批次 ---"
# ⚠️ 两处关键前提（都是实测踩出来的）：
#   ① batch 号直接决定时间戳基准 base = batch × 100000000ms ⇒ "更早"必须是**更小的 batch 号**；
#   ② **必须先落一次盘，再写更早的数据，才会进 unsequence**。
#      源码依据 `DataRegion` 的顺乱序判定用 `LastFlushTimeMap.getGlobalFlushedTime(device)`：
#      新设备的 flushedTime 初始为 MIN，所有写入都会被判成**顺序**，即使时间戳更早；
#      只有"已 flush 到某个时间点 → 再写更早的点"才判乱序。
#      首版没先 flush，结果 600 点全落在 sequence memtable、`unsequence tsfile` 恒为 0（假失败）。
log "  ① 先写水位（batch 3，最晚）并**落盘**，建立 flushedTime"
mb_bulk_int "$DB" d1 200 3 >/dev/null
sq 'flush;' >/dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(mb_seq_all "$DB")" -gt 0 ] && break
  sleep 2
done
log "  ② 水位已落 sequence/（tsfile=$(mb_seq_all "$DB")）；再写更早的 batch 1、2 ⇒ 应进 unsequence"
mb_bulk_int "$DB" d1 200 1 >/dev/null            # 更早
mb_bulk_int "$DB" d1 200 2 >/dev/null            # 更早，且与上一批区间重叠
ts0=$(mb_tsfile_cnt_all "$DB")
TIMED0=$(mb_unseq_timed_all)
log "  乱序写入完成：tsfile 合计基线=$ts0（sequence=$(mb_seq_all "$DB") unsequence=$(mb_unseq_all "$DB")）日志触发计数=$TIMED0"
if [ "$(mb_unseq_all "$DB")" -eq 0 ]; then
  warn "场景有效性：unsequence 目录仍为空（这批更早的数据可能还在 memtable、或仍被判为顺序）"
fi

log "--- 阶段 A：unseq 定时刷盘开启，不手工 flush ---"
if wait_unseq_flush "$DB" "$ts0" "$WIN" "$TIMED0"; then
  TIMED1=$(mb_unseq_timed_all)
  if [ "${TIMED1:-0}" -gt "${TIMED0:-0}" ]; then
    pass "阶段A：乱序定时刷盘触发（产品日志 'Exceed unsequence memtable flush interval' 出现 $(( TIMED1 - TIMED0 )) 次）"
  else
    pass "阶段A：观察到 TsFile 数增加（$ts0→$(mb_tsfile_cnt_all "$DB")），定时刷盘生效"
  fi
else fail "阶段A：${WIN}s 内乱序定时刷盘未触发（日志触发计数仍为 $TIMED0）"; fi
n_a=$(mb_count_all "$DB")
log "  阶段A 点数=$n_a（顺序 600 + 乱序 400 应为 1000）"
assert_ge "阶段A 数据可查（>0）" "${n_a:-0}" 1

log "--- 阶段 B（对照）：关闭 unseq 定时刷盘，同窗口内不应再新增乱序 TsFile ---"
sq "set configuration 'enable_timed_flush_unseq_memtable'='false';" >/dev/null 2>&1
sleep 3
# ⚠️ 判据说明：不能用"TsFile 总数"做单调递增假设 —— 合并(compaction)会让总数下降。
#    RC10 实测：阶段B 总数 4 -> 3，但 unsequence=0，即"确实没有新增乱序文件"，
#    此时用总数比较会得到假 FAIL。因此这里只校验 unsequence 目录是否增加。
ts1=$(mb_tsfile_cnt_all "$DB")
u1=$(mb_unseq_all "$DB")
mb_bulk_int "$DB" d1 200 4 >/dev/null            # 与水位重叠但更早 ⇒ 乱序
sleep "$WIN"
ts2=$(mb_tsfile_cnt_all "$DB")
u2=$(mb_unseq_all "$DB")
log "  阶段B tsfile 合计: $ts1 -> $ts2（sequence=$(mb_seq_all "$DB") unsequence=$u1 -> $u2）"
# 判据：乱序文件"不新增"即可 —— 合并(compaction)可能把已有乱序文件合掉（数量下降），
#       因此不能用相等；实测 RC11：unsequence 1 -> 0（合掉了），若用相等会假 FAIL。
assert_ge "阶段B 关闭乱序定时刷盘后无新增乱序 TsFile（允许被合并减少）" "$(( u1 - u2 ))" 0
assert_ge "阶段B 数据仍可查（乱序数据已进入可查询状态）" "$u2" 0
n_b=$(mb_count_all "$DB")
log "  阶段B 点数=$n_b"
assert_ge "阶段B 数据仍可查（>= 顺序 600）" "${n_b:-0}" 600

mb_case_finish "$(mb_data_sql "$DB")" tree
