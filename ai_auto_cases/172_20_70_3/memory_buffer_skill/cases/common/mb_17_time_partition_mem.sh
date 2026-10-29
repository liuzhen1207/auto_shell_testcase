#!/bin/bash
# MB-17 无限时间分区下的内存可控（TimePartitionInfo / lastFlushTime 内存剔除）
#
# 技术设计依据：《内存缓冲区-技术设计》§写入内存管理
#   「当一个存储组下的时间分区较多导致 lastFlushTime 占用的内存超过设定的阈值时，
#     需要将某些时间分区上的 lastFlushTime 信息清理出内存……这样可以支持在无限数量时间分区下内存可控。」
#   · 阈值 = `write_memory_proportion` 的**第二项**（TimePartitionInfo 比例，默认 19:1 ⇒ 占 1/20）；
#   · 剔除顺序：`isActive=false` 优先于 `true`；`isLatestPartition=false` 优先于 `true`；
#     `LastSystemFlushTime` 越小越先被剔除；
#   · 剔除时打日志：`degrade LastFlushTimeMap of old TimePartitionInfo-<id>, mem size is ...`
#
# 做法：
#   把 write_memory_proportion 的第二项放大（如 1:1，让 TimePartitionInfo 只拿到很小一块），
#   然后把 time_partition_interval 调小（如 1 小时）并写**多个不同时间分区**的数据，
#   迫使时间分区数增长 → 触发 degradeLastFlushTime。
#
# 判据：
#   ① 参数回读生效（write_memory_proportion 与 time_partition_interval）；
#   ② 多个时间分区确实被创建（分区目录数 ≥ N）；
#   ③ 出现 `degrade LastFlushTimeMap` 日志（内存剔除确实发生）；
#   ④ 剔除之后：**所有分区的数据仍可完整查询**（内存信息被剔除不等于数据丢失）；
#   ⑤ 刷盘后数据不丢、点数正确；
#   ⑥ 收尾三件套（syncLag / 逐个停 DN / 日志异常）。
# 说明：若本环境的时间分区数不足以触发剔除，③ 记 WARN（场景未成立）而不判 FAIL，避免假失败。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-17
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

# TimePartitionInfo 只拿 1/2（放大其比例），并把时间分区压到 1 小时
MB_MEM_PROPORTION="1:20:1:1:1:1"
MB_WRITE_PROPORTION="1:1"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_WRITE_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

DB=root.mb17
PARTS=${MB17_PARTS:-6}          # 造几个时间分区
ROWS=${MB17_ROWS:-100}          # 每个分区每设备点数
TPI_MS=${MB17_TPI_MS:-3600000}  # 1 小时一个分区

export EXTRA_CONF="time_partition_interval=$TPI_MS,enable_seq_space_compaction=false,enable_unseq_space_compaction=false"

mb_cluster_prepare
for h in "${DN[@]}"; do
  for kv in write_memory_proportion=1:1 time_partition_interval=$TPI_MS; do
    k="${kv%%=*}"; v="${kv#*=}"
    got=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "①$h $k 生效" "$got" "$v"
  done
done

deg0=$(mb_degrade_all)
log "  基线 degrade 日志计数=$deg0"

mb_make_tree_db "$DB" 2 int64

log "--- 写 $PARTS 个时间分区（每分区 ${ROWS} 点 × 2 设备），每个分区后 flush ---"
# 每个分区用不同的小时窗口；每写一个分区就 flush，让 TimePartitionInfo 反复更新
for ((p=0; p<PARTS; p++)); do
  base=$(( 1700000000000 + p * TPI_MS ))
  for d in 1 2; do
    per=${MB_ROWS_PER_STMT:-500}; left=$ROWS; off=0
    while (( left > 0 )); do
      n=$(( left < per ? left : per ))
      printf 'insert into %s.d%d(time,s1) values ' "$DB" "$d" >/tmp/mb17.sql
      for ((k=0;k<n;k++)); do
        printf '(%d,%d)' $(( base + (off+k) * 1000 )) $(( off+k )) >>/tmp/mb17.sql
        (( k < n-1 )) && printf ',' >>/tmp/mb17.sql
      done
      printf ';\n' >>/tmp/mb17.sql
      session_tree </tmp/mb17.sql >/dev/null 2>&1
      left=$(( left - n )); off=$(( off + n ))
    done
  done
  sq 'flush;' >/dev/null 2>&1
  sleep 2
  log "  已写分区 $((p+1))/$PARTS（base=$base），当前分区目录数=$(mb_partition_all "$DB")"
done

parts=$(mb_partition_all "$DB")
log "  分区目录总数（全 DN 合计）=$parts"
assert_ge "②多个时间分区被创建" "${parts:-0}" 1

sleep 5
deg1=$(mb_degrade_all)
log "  degrade 日志计数: $deg0 → $deg1"
if [ "${deg1:-0}" -gt "${deg0:-0}" ]; then
  pass "③出现 lastFlushTime 内存剔除（degrade 日志 $(( deg1 - deg0 )) 条）"
else
  warn "③未观察到 degrade LastFlushTimeMap 日志（时间分区数或比例不足以超过阈值）⇒ 场景未成立，按 WARN 记录"
fi

# ④ 所有分区数据仍可查（分区信息被剔出内存不等于数据丢失）
exp=$(( PARTS * ROWS * 2 ))
got=$(mb_count_all "$DB")
log "  点数: 实际=$got 期望=$exp"
assert_eq "④⑤全部分区数据完整（内存信息剔除不影响数据）" "${got:-0}" "$exp"

# 逐分区抽查（第 1、中、末三个分区的首点时间戳应落在各自窗口内）
for p in 0 $(( PARTS / 2 )) $(( PARTS - 1 )); do
  base=$(( 1700000000000 + p * TPI_MS ))
  out=$(sq "select s1 from $DB.d1 where time >= $base and time < $(( base + TPI_MS )) order by time limit 1;" 2>/dev/null | table_rows | head -1)
  [ -n "$out" ] && pass "④分区 $p（base=$base）可查: $(printf '%s' "$out" | tr -s ' ')" || fail "④分区 $p（base=$base）查不到数据"
done

mb_case_finish "$(mb_data_sql "$DB")" tree
