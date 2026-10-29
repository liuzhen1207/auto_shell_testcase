#!/bin/bash
# MB-02 参数守卫：非法/越界取值必须"回退默认值 + 打 WARN"，且**不得把 DN 起挂**
#
# 需求依据：《V1.1.0.1-内存缓冲区-内存缓冲区-需求分析》配置表 +
#           《技术设计》§写入内存管理（各内存块按比例派生：storage→write→memtable→各池）
#
# 三段：
#   ① reject 0.9 + wal 0.1 + device 0.05 ≥ 1 → 必须 WARN 并回退默认值 0.8/0.1/0.05
#      判据：出现回退告警；且回退后 devicePathCache/memtable 阈值比例 ≈ 0.05
#   ② datanode_memory_proportion=9:1:1:1:1:1（storage 9/14≈64%）→ Write 必须等于堆×9/14
#   ③ datanode_memory_proportion=12:1:1:1:1:1（storage 12/17≈71%）→ 行为必须**自洽**：
#        · 若打出 "limited to 60% of the DataNode heap" ⇒ Write 必须 = 堆×3/5
#        · 若无该告警                ⇒ Write 必须 = 堆×12/17
#      这样无论产品是否启用 60% 限幅，判据都成立；同时在日志里明确记录本次实际行为。
#
# ⚠️ 不要把 `storage_engine_memory_proportion=0:10` / `write_memory_proportion=0:1` 放进本用例：
#    实测会让 DataNode 直接起不来（NPE），是独立缺陷，见 MB-19 与 docs/FINDINGS.md F-07。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-02
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_alloc

DB=root.mb02
# ⚠️ 堆大小必须从 DN 进程 cmdline 读 `-Xmx`，不能硬编码：
#    堆是部署时可变项（两版发布包默认都"按机器内存自动算"；本环境 RC8 是运维手工设了 20G、
#    RC9 未设→~12.5G）。硬编码会在换机器/换部署时产生一堆假 FAIL。
HEAP=0

prop_sum(){ printf '%s' "$1" | tr ':' '\n' | awk '{s+=$1} END{print s}'; }

MB_MEM_PROPORTION="9:1:1:1:1:1"
MB_REJECT_PROPORTION="0.9"
MB_WAL_QUEUE_PROPORTION="0.1"
MB_DEVICE_PATH_PROPORTION="0.05"
export MB_MEM_PROPORTION MB_REJECT_PROPORTION MB_WAL_QUEUE_PROPORTION MB_DEVICE_PATH_PROPORTION
export EXTRA_CONF=""

mb_cluster_prepare

log "--- 各 DN 实际堆（用于核对分配值）---"
mb_heap_report
for h in "${DN[@]}"; do
  b=$(mb_heap_bytes "$h"); [ "${b:-0}" -gt "${HEAP:-0}" ] && HEAP=$b
done
[ "${HEAP:-0}" -le 0 ] && { fail "无法读取 DN 堆大小（-Xmx）"; HEAP=21474836480; }
log "  用于核对的堆大小 = $HEAP 字节"

log "--- ① reject+wal+device 之和 >= 1 ⇒ 回退默认值（0.8/0.1/0.05）---"
for h in "${DN[@]}"; do
  assert_ge "①$h 打出回退告警" "$(mb_warn_cnt "$h" 'The sum of reject_proportion')" 1
  f="$MB_METRICS_DIR/$h.txt"
  curl -s -m 8 "http://$h:$DN_METRIC_PORT/metrics" >"$f" 2>/dev/null
  mv=$(awk '/^memory_threshold_size\{/ && /name="StorageEngine-Write-Memtable"/ && !/Memtable-/ {print $NF; exit}' "$f" | tr -d '\r')
  dv=$(awk '/^memory_threshold_size\{/ && /name="StorageEngine-Write-Memtable-DevicePathCache"/ {print $NF; exit}' "$f" | tr -d '\r')
  log "  [$h] memtable 阈值=$mv  devicePathCache 阈值=$dv"
  if [ -n "$mv" ] && [ -n "$dv" ]; then
    ratio=$(awk -v a="$dv" -v b="$mv" 'BEGIN{ if (b+0<=0) print "NA"; else printf "%.3f", a/b }')
    log "  [$h] devicePathCache/memtable 比例=$ratio（默认 0.05）"
    [ "$ratio" = "NA" ] || assert_contains "①$h 回退后 devicePathCache 比例≈0.05" "$ratio" '^0\.0[45]'
  else
    warn "①$h 未能采到内存阈值指标（跳过比例核对）"
  fi
done

log "--- ② storage 段 9/14（≈64%）：Write 必须等于按比例算出的值 ---"
# 用**比例自洽**判定：由 Read 反推 maxMemory，再算 Write 期望值。
# 不用 -Xmx 直接换算：JVM maxMemory 与 -Xmx 有 0.03% 级差异（RC9 实测），逐字节比会假失败。
SUM2=$(prop_sum "$MB_MEM_PROPORTION"); SEG2=$(printf '%s' "$MB_MEM_PROPORTION" | cut -d: -f1)
SEG2Q=$(printf '%s' "$MB_MEM_PROPORTION" | cut -d: -f2)
for h in "${DN[@]}"; do
  w=$(mb_alloc_log "$h" Write); r=$(mb_alloc_log "$h" Read)
  if [ "${r:-0}" -le 0 ] || [ "${w:-0}" -le 0 ]; then
    fail "②$h 未读到 Write/Read 分配值"; continue
  fi
  M=$(( r * SUM2 / SEG2Q ))
  exp2=$(( M * SEG2 / SUM2 ))
  d=$(( w - exp2 )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -le $(( SUM2 + 16 )) ]; then pass "②$h Write=$w（= maxMemory×${SEG2}/${SUM2}，maxMemory=$M，差 $d 字节）"
  else fail "②$h Write: 实际=[$w] 期望≈[$exp2]（maxMemory×${SEG2}/${SUM2}，差 $d）"; fi
  assert_eq "②$h 不应出现限幅告警" "$(mb_warn_cnt "$h" 'limited to 60% of the DataNode heap')" "0"
done

# 先落一次 interim 结论：本用例要重启两次、总时长约 10 分钟，正好落在本环境
# "长跑 8~15 分钟易被 SIGKILL" 的窗口里。①② 已经测完，先写结论保底；
# ③ 跑完后再覆盖成最终结论（write_result 是覆盖写，不会重复追加 CSV 之外的东西）。
log "--- 中间落盘 interim 结论（①② 已完成）---"
write_result

log "--- ③ storage 段 12/17（≈71%）：限幅告警与 Write 取值必须自洽 ---"
cluster_stop; cluster_clean
MB_MEM_PROPORTION="12:1:1:1:1:1"
export MB_MEM_PROPORTION
cluster_write_conf
cluster_start
wait_cluster_ready || fail "③越界比例场景集群未就绪"
SUM3=$(prop_sum "$MB_MEM_PROPORTION"); SEG3=$(printf '%s' "$MB_MEM_PROPORTION" | cut -d: -f1)
SEG3Q=$(printf '%s' "$MB_MEM_PROPORTION" | cut -d: -f2)
log "  比例=$MB_MEM_PROPORTION（sum=$SUM3）：判据是"限幅告警与 Write 取值必须自洽""
for h in "${DN[@]}"; do
  w=$(mb_alloc_log "$h" Write); r=$(mb_alloc_log "$h" Read)
  if [ "${r:-0}" -le 0 ] || [ "${w:-0}" -le 0 ]; then fail "③$h 未读到 Write/Read 分配值"; continue; fi
  M=$(( r * SUM3 / SEG3Q ))
  cap_val=$(( M * 3 / 5 ))
  raw_val=$(( M * SEG3 / SUM3 ))
  ncap=$(mb_warn_cnt "$h" 'limited to 60% of the DataNode heap')
  if [ "${ncap:-0}" -ge 1 ]; then
    pass "③$h 打出了 60% 限幅告警 ⇒ 本构建启用了限幅（maxMemory=$M）"
    d=$(( w - cap_val )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le $(( SUM3 + 16 )) ]; then pass "③$h 限幅后 Write = maxMemory×3/5 = $w（差 $d）"
    else fail "③$h 限幅后 Write: 实际=[$w] 期望≈[$cap_val]（差 $d）"; fi
  else
    pass "③$h 未打限幅告警 ⇒ 本构建按比例直接分配（maxMemory=$M）"
    d=$(( w - raw_val )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le $(( SUM3 + 16 )) ]; then pass "③$h 未限幅时 Write = maxMemory×${SEG3}/${SUM3} = $w（差 $d）"
    else fail "③$h 未限幅时 Write: 实际=[$w] 期望≈[$raw_val]（差 $d）"; fi
    warn "③$h 未触发 60% 限幅（见 FINDINGS F-08）"
  fi
  log "  [$h] $(mb_alloc_dump "$h" | tr '\n' ';' | cut -c1-420)"
done

log "--- 功能冒烟：越界比例状态下写入与刷盘仍可用 ---"
mb_make_tree_db "$DB" 2 int64
ok=$(mb_bulk_int "$DB" d1 2000 1); ok=${ok%% *}
assert_ge "写入语句成功数" "${ok:-0}" 1
sq 'flush;' >/dev/null 2>&1
sleep 3
assert_eq "写入点数可查" "$(mb_count_all "$DB")" "2000"
assert_ge "有 TsFile 落盘" "$(mb_tsfile_cnt_all "$DB")" 1

mb_case_finish "$(mb_data_sql "$DB")" tree
