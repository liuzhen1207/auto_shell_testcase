#!/bin/bash
# MB-01 内存分配事实：datanode_memory_proportion 变更后，各内存块初始分配值与比例一致
#   期望（设 DataNode 堆为 H，比例 2:4:1:1:1:1，sum=10）：
#     allocateMemoryForWrite        = H * 2/10
#     allocateMemoryForRead         = H * 4/10
#   ⚠️ H **不写死**：它随部署而变（本环境 RC8 手工设 20G，RC9 走默认自动算 = 12.50G，
#      因此下面的断言全部用"比例自洽"表达，不出现任何绝对字节数常量）。
#     allocateMemoryForSchema       = 2147483648
#     allocateMemoryForConsensus    = 2147483648
#     allocateMemoryForPipe         = 2147483648
#     allocateMemoryForAutoResizingBuffer = 2147483648 / 2 = 1073741824
#   判据：日志实测值 == 期望值；且无"比例非法/被限幅"告警。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-01
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_alloc

MB_MEM_PROPORTION="2:4:1:1:1:1"
export MB_MEM_PROPORTION
DB=root.mb01
export EXTRA_CONF=""

mb_cluster_prepare

log "--- 校验各内存块初始分配值（比例 $MB_MEM_PROPORTION）---"
# ⚠️ 两条历史坑，都已规避：
#   ① **不要硬编码堆大小**：堆是**部署时可变**的 —— 两版发布包默认都是"按机器内存自动算"
#      （`#ON_HEAP_MEMORY="2G"` 在 RC8/RC9 里都是注释掉的，两版该文件 md5 完全相同），
#      而本环境 RC8 是运维手工加了 ON_HEAP_MEMORY="20G"、RC9 未加（实测 -Xmx12804M / 12.50GB）。
#      把 20G 写死会产生 35 条假 FAIL（已踩过）。
#   ② **也不要拿 -Xmx 精确换算期望值**：JVM 的 `Runtime.maxMemory()` 与 `-Xmx` 不完全相等
#      （实测差约 0.03%，12804M→maxMemory≈12808M），逐字节比较仍会失败。
#   ⇒ 判据改为**比例自洽**：以 Write 为基准反推 maxMemory，再验证其余内存块是否严格满足比例；
#      同时把反推的 maxMemory 与 -Xmx 的偏差作为"堆识别是否合理"的软校验（<5% 记 PASS）。
log "--- 各 DN 实际堆 ---"
mb_heap_report
HEAP=0
for h in "${DN[@]}"; do
  b=$(mb_heap_bytes "$h")
  [ "${b:-0}" -gt "${HEAP:-0}" ] && HEAP=$b
done
log "  各 DN -Xmx 最大值 = $HEAP 字节（$(awk -v x="$HEAP" 'BEGIN{printf "%.2f", x/1024/1024/1024}') GB）"

# 从比例串里取各段
SEG_STORAGE=$(printf '%s' "$MB_MEM_PROPORTION" | cut -d: -f1)
SEG_QUERY=$(printf '%s'   "$MB_MEM_PROPORTION" | cut -d: -f2)
SEG_SCHEMA=$(printf '%s'  "$MB_MEM_PROPORTION" | cut -d: -f3)
SEG_CONS=$(printf '%s'    "$MB_MEM_PROPORTION" | cut -d: -f4)
SEG_PIPE=$(printf '%s'    "$MB_MEM_PROPORTION" | cut -d: -f5)
SEG_AUTO=$(printf '%s'    "$MB_MEM_PROPORTION" | cut -d: -f6)
SEG_SUM=$(( SEG_STORAGE + SEG_QUERY + SEG_SCHEMA + SEG_CONS + SEG_PIPE + SEG_AUTO ))
log "  比例分段: storage=$SEG_STORAGE query=$SEG_QUERY schema=$SEG_SCHEMA consensus=$SEG_CONS pipe=$SEG_PIPE autoResizing=$SEG_AUTO (sum=$SEG_SUM)"

for h in "${DN[@]}"; do
  log "  [$h] $(mb_alloc_dump "$h" | tr '\n' ';' | cut -c1-700)"
  w=$(mb_alloc_log "$h" Write)
  r=$(mb_alloc_log "$h" Read)
  sc=$(mb_alloc_log "$h" Schema)
  co=$(mb_alloc_log "$h" Consensus)
  pi=$(mb_alloc_log "$h" Pipe)
  au=$(mb_alloc_log "$h" AutoResizingBuffer)
  if [ -z "$w" ] || [ "${w:-0}" -le 0 ]; then
    fail "①$h 未能读到 allocateMemoryForWrite（内存分配日志缺失）"
    continue
  fi
  # 由 Write 反推 maxMemory：Write = maxMemory × storage / sum
  M=$(( w * SEG_SUM / SEG_STORAGE ))
  log "  [$h] 由 Write 反推 maxMemory=$M 字节（$(awk -v x="$M" 'BEGIN{printf "%.2f", x/1024/1024/1024}') GB）"

  # ① 各块严格满足比例（允许整数除法的 ±1 误差）
  chk_ratio(){ local name=$1 got=$2 seg=$3 exp
    exp=$(( M * seg / SEG_SUM ))
    local d=$(( got - exp )); [ "$d" -lt 0 ] && d=$(( -d ))
    # 容差说明：M 由 Read 反推（一轮整数除法）、exp 再乘一次比例（第二轮除法），
    # 两轮舍入的累积误差上限约等于"比例总和"。实测 GB 级数值会差 3~5 字节，
    # 相对误差 ~1e-10，属纯舍入；真正的配置错误都是 MB 级差异，不会被放过。
    local tol=$(( SEG_SUM + 16 ))
    if [ "$d" -le "$tol" ]; then pass "①$h $name = $got（= maxMemory×$seg/$SEG_SUM，差 $d 字节 ≤ 容差 $tol）"
    else fail "①$h $name: 实际=[$got] 期望≈[$exp]（maxMemory×$seg/$SEG_SUM，差 $d 字节 > 容差 $tol）"; fi
  }
  chk_ratio "Read" "$r" "$SEG_QUERY"
  chk_ratio "Schema" "$sc" "$SEG_SCHEMA"
  chk_ratio "Consensus" "$co" "$SEG_CONS"
  chk_ratio "Pipe" "$pi" "$SEG_PIPE"
  # AutoResizingBuffer = maxMemory × SEG_AUTO / SEG_SUM / 2
  exp_auto=$(( M * SEG_AUTO / SEG_SUM / 2 ))
  da=$(( au - exp_auto )); [ "$da" -lt 0 ] && da=$(( -da ))
  if [ "$da" -le $(( SEG_SUM + 16 )) ]; then pass "①$h AutoResizingBuffer = $au（= maxMemory×$SEG_AUTO/$SEG_SUM/2，差 $da 字节）"
  else fail "①$h AutoResizingBuffer: 实际=[$au] 期望≈[$exp_auto]（差 $da）"; fi
  # SchemaEngine 内部 5:4:1
  sr=$(mb_alloc_log "$h" SchemaRegion)
  exp_sr=$(( sc * 5 / 10 ))
  dsr=$(( sr - exp_sr )); [ "$dsr" -lt 0 ] && dsr=$(( -dsr ))
  if [ "$dsr" -le $(( SEG_SUM + 16 )) ]; then pass "①$h SchemaRegion = $sr（= Schema×5/10，差 $dsr 字节）"
  else fail "①$h SchemaRegion: 实际=[$sr] 期望≈[$exp_sr]（Schema 的 5/10，差 $dsr）"; fi

  # ② 堆识别软校验：反推的 maxMemory 应接近 -Xmx（JVM maxMemory 与 Xmx 本来就有小差异）
  if [ "${HEAP:-0}" -gt 0 ]; then
    dev=$(awk -v a="$M" -v b="$HEAP" 'BEGIN{printf "%.3f", ((a>b)?(a-b):(b-a))/b*100}')
    if awk -v d="$dev" 'BEGIN{exit !(d+0 < 5)}'; then
      pass "②$h 反推 maxMemory 与 -Xmx 偏差 ${dev}%（<5%，堆识别合理）"
    else
      warn "②$h 反推 maxMemory 与 -Xmx 偏差 ${dev}%（>=5%，请核对是否读错进程）"
    fi
  fi
  assert_eq "③$h 无比例/限幅告警" "$(mb_warn_cnt "$h" 'datanode_memory_proportion must|proportion is illegal|limited to 60%')" "0"
done

log "--- 功能性冒烟：写入/查询/刷盘仍可用 ---"
mb_make_tree_db "$DB" 2 int64
ok=$(mb_bulk_int "$DB" d1 2000 1)
assert_ge "写入语句成功数" "$ok" 1
sq 'flush;' >/dev/null 2>&1
cnt=$(mb_count_all "$DB")
assert_eq "写入点数可查" "$cnt" "2000"
assert_ge "有 TsFile 落盘" "$(mb_tsfile_cnt_all "$DB")" 1
assert_ge "内存实际占用（Write-Memtable 相关）有采样" "$(mb_actual "${DN[0]}" 'StorageEngine-Write-Memtable-DevicePathCache')" 0

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
