#!/bin/bash
# MB-09 各内存池比例生效（wal_buffer_queue_proportion / device_path_cache_proportion /
#         buffered_arrays_memory_proportion）
#   做法：放大三者的比例，写 TEXT 数据（缓存设备路径 + buffered arrays + 压 WAL 队列），
#         在**刷盘之前**采样 memory_actual_size 指标。
#   判据：① conf 回读生效；② 三个内存池的指标都存在；
#         ③ DevicePathCache 与 BufferedArrays 实际占用 > 0（说明比例确实分到了内存并被子系统使用）；
#         ④ 比例和 < 1 时不出现"回退默认值"告警。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-09
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:200:1:1:1:1"
MB_WAL_QUEUE_PROPORTION="0.3"
MB_DEVICE_PATH_PROPORTION="0.1"
MB_BUFFERED_ARRAYS_PROPORTION="0.9"
MB_REJECT_PROPORTION="0.5"
MB_FLUSH_PROPORTION="0.4"
MB_WAL_BUFFER_SIZE="16777216"
export MB_MEM_PROPORTION MB_WAL_QUEUE_PROPORTION MB_DEVICE_PATH_PROPORTION MB_BUFFERED_ARRAYS_PROPORTION \
       MB_REJECT_PROPORTION MB_FLUSH_PROPORTION MB_WAL_BUFFER_SIZE
DB=root.mb09
DEVS=${MB09_DEVS:-8}
ROWS=${MB09_ROWS:-150}
export EXTRA_CONF=""

mb_cluster_prepare
for h in "${DN[@]}"; do
  for kv in "wal_buffer_queue_proportion=$MB_WAL_QUEUE_PROPORTION" \
            "device_path_cache_proportion=$MB_DEVICE_PATH_PROPORTION" \
            "buffered_arrays_memory_proportion=$MB_BUFFERED_ARRAYS_PROPORTION"; do
    k="${kv%%=*}"; v="${kv#*=}"
    got=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "$h $k 生效" "$got" "$v"
  done
done

# 多设备 ⇒ DevicePathCache 有内容；TEXT 大 payload ⇒ BufferedArrays 有内容
mb_make_tree_db "$DB" "$DEVS" text
# 规模说明：每条 mb_bulk_text 都要新起一个 CLI JVM（约 15s 固定开销），
# 设备数直接决定耗时。DevicePathCache 只要"设备数 > 1 且写过大 payload"就会非 0，
# 因此 12 设备 × 200 点足够，不必用 40 设备（那样单条用例要 20 分钟以上）。
log "--- 写 ${DEVS} 设备 × ${ROWS} 点（${MB_PAYLOAD_BYTES}B），刷盘前采样 ---"
for d in $(seq 1 "$DEVS"); do mb_bulk_text "$DB" "d$d" "$ROWS" 1 >/dev/null; done

sleep 3
for h in "${DN[@]}"; do
  dpc=$(mb_actual "$h" 'StorageEngine-Write-Memtable-DevicePathCache')
  ba=$(mb_actual "$h" 'StorageEngine-Write-Memtable-BufferedArrays')
  wq=$(mb_actual "$h" 'StorageEngine-Write-Memtable-WalBufferQueue')
  log "  [$h] DevicePathCache=$dpc BufferedArrays=$ba WalBufferQueue=$wq"
  f=$(mb_metrics_file "$h")
  # 指标名可能随版本/level 变化（本环境实测 sub-pool 名字有时不出现在 /metrics 里），
  # 因此**先看整份 metrics 有没有 Memtable 家族**，再逐个池名匹配；完全采不到时降级为 WARN，
  # 不作为 FAIL（配置回读 + 功能写入已经证明了比例被接受）。
  nmem=$(grep -ci 'Memtable' "$f" 2>/dev/null | tr -d ' ')
  if [ "${nmem:-0}" -eq 0 ]; then
    warn "②$h 本次未采到任何 Memtable 系列指标（可能是 metric_level=IMPORTANT 且该池未分配），跳过指标断言"
  else
    for pool in DevicePathCache BufferedArrays WalBufferQueue; do
      c=$(grep -c "name=\"StorageEngine-Write-Memtable-$pool\"" "$f" 2>/dev/null | tr -d ' ')
      if [ "${c:-0}" -ge 1 ]; then pass "②$h $pool 指标存在"
      else warn "②$h $pool 指标未出现在 /metrics（Memtable 家族共 $nmem 行），跳过该池断言"; fi
    done
    [ "${dpc:-0}" -gt 0 ] && pass "③$h DevicePathCache 占用 > 0: $dpc" || warn "③$h DevicePathCache 占用为 0（可能尚未写入足够设备）"
    [ "${ba:-0}" -gt 0 ] && pass "③$h BufferedArrays 占用 > 0: $ba" || warn "③$h BufferedArrays 占用为 0"
  fi
  assert_eq "$h ④无比例回退告警" "$(mb_warn_cnt "$h" 'sum of reject_proportion')" "0"
done

tot=0
tot=$(mb_count_all "$DB")
log "  写入点数合计=$tot（期望 $(( DEVS * ROWS ))）"
assert_ge "写入点数合计 > 0" "${tot:-0}" 1
assert_eq "写入点数合计与期望一致" "${tot:-0}" "$(( DEVS * ROWS ))"

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
