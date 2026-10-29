#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 —— 专用 helper（在 lib/common.sh 之上）
#   ① 内存分配事实（启动日志 allocateMemoryForXxx）
#   ② 内存/刷盘指标（DN :9092/metrics）
#   ③ 刷盘 / 拒绝 / WAL 快照 的日志证据
#   ④ 内存缓冲区相关的等待与重启/强杀辅助
# ============================================================================

MB_METRICS_DIR="/tmp/mb_metrics"
mkdir -p "$MB_METRICS_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# ① 启动日志里的内存分配事实
#   DN 启动时 DataNodeMemoryConfig 会打印：
#     initial allocateMemoryForWrite / Read / Schema / Consensus / Pipe / AutoResizingBuffer
#     allocateMemoryForSchemaRegion / SchemaCache / PartitionCache
# ---------------------------------------------------------------------------
mb_alloc_log(){ local h=$1 key=$2
  sshx "$h" "grep -hoE 'initial allocateMemoryFor${key} = [0-9]+|allocateMemoryFor${key} = [0-9]+' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -1 | grep -oE '[0-9]+$'" | tr -dc '0-9'
}
mb_alloc_dump(){ local h=$1
  sshx "$h" "grep -hE '^[0-9-]+ [0-9:,]+ \[main\] INFO +o\.a\.i\.d\.c\.DataNodeMemoryConfig' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -12" \
    | sed -E 's/^[0-9-]+ [0-9:,]+ \[main\] INFO +o\.a\.i\.d\.c\.DataNodeMemoryConfig:[0-9]+ - //'
}
mb_alloc_sum(){ local h=$1
  sshx "$h" "grep -hoE 'initial allocateMemoryFor(Write|Read|Schema|Consensus|Pipe|AutoResizingBuffer) = [0-9]+' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -oE '[0-9]+$' | awk '{s+=\$1} END{print s+0}'" | tr -dc '0-9'
}
mb_heap_max(){ local h=$1
  sshx "$h" "grep -hoE 'Xmx[0-9]+[gGmM]' /proc/\$(pgrep -f 'com\.timecho\.iotdb\.DataNode' | head -1)/cmdline 2>/dev/null | head -1" | tr -dc '0-9gGmM'
}
# 内存分配相关的 WARN（非法取值回退默认值、storage engine 超 60% 被限幅）
mb_warn_cnt(){ local h=$1 p=$2
  sshx "$h" "grep -hcE '$p' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'
}
mb_warn_lines(){ local h=$1 p=$2
  sshx "$h" "grep -hE '$p' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -5" | cut -c1-260
}

# ---------------------------------------------------------------------------
# ② 指标（直连 DN :9092/metrics；带 2 秒内缓存，避免一条用例里反复抓 500KB）
# ---------------------------------------------------------------------------
mb_metrics_file(){ local h=$1 f="$MB_METRICS_DIR/$h.txt" age
  if [ -f "$f" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    [ "$age" -lt 2 ] && { printf '%s' "$f"; return 0; }
  fi
  curl -s -m 10 "http://$h:$DN_METRIC_PORT/metrics" > "$f" 2>/dev/null
  printf '%s' "$f"
}
# memory_actual_size{name="X",type="OnHeap"} 的值
mb_actual(){ local h=$1 name=$2 type=${3:-OnHeap} f
  f=$(mb_metrics_file "$h")
  awk -v n="$name" -v t="$type" '
    $0 ~ /^memory_actual_size\{/ && index($0, "name=\"" n "\"") && index($0, "type=\"" t "\"") {
      v=$NF; s+=v } END { printf "%.0f", s+0 }' "$f" 2>/dev/null
}
# 某 DN 上所有 DataRegion 的 memCost 之和（memtable 里尚未落盘的内存）
mb_region_mem(){ local h=$1 f
  f=$(mb_metrics_file "$h")
  awk '/^data_region_mem_cost\{/ {v=$NF; s+=v} END {printf "%.0f", s+0}' "$f" 2>/dev/null
}
# 全集群 memCost 之和
mb_region_mem_all(){ local h s=0 v; for h in "${DN[@]}"; do v=$(mb_region_mem "$h"); s=$(( s + ${v:-0} )); done; echo "$s"; }
# 累计刷盘次数（flush_memtable_count_total）
mb_flush_total(){ local h=$1 f
  f=$(mb_metrics_file "$h")
  awk '/^flush_memtable_count_total\{/ {v=$NF; s+=v} END {printf "%.0f", s+0}' "$f" 2>/dev/null
}
mb_flush_all(){ local h s=0 v; for h in "${DN[@]}"; do v=$(mb_flush_total "$h"); s=$(( s + ${v:-0} )); done; echo "$s"; }
# 活跃 memtable 数
mb_active_memtable(){ local h=$1 f
  f=$(mb_metrics_file "$h")
  awk '/^active_memtable_count_total\{/ {v=$NF; s+=v} END {printf "%.0f", s+0}' "$f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ③ 日志证据
# ---------------------------------------------------------------------------
mb_reject_enter_cnt(){ local h=$1
  sshx "$h" "grep -hc 'Change system to reject status' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_reject_enter_all(){ local h s=0 v; for h in "${DN[@]}"; do v=$(mb_reject_enter_cnt "$h"); s=$(( s + ${v:-0} )); done; echo "$s"; }
mb_flush_call_cnt(){ local h=$1
  sshx "$h" "grep -hcE 'call for flushing|call flush' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_reject_exception_cnt(){ local h=$1
  sshx "$h" "grep -hcE 'Total database MemCost .* is over than memorySizeForWriting|WriteProcessRejectException' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_wal_snapshot_cnt(){ local h=$1
  sshx "$h" "grep -hcE 'snapshot' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_flush_done_cnt(){ local h=$1
  sshx "$h" "grep -hcE 'Async close tsfile|flush .* successfully|Flush .* successfully' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_tsfile_cnt(){ local h=$1 db=${2:-}
  sshx "$h" "sudo find $DB_DIR/data/datanode -path '*${db}*' -name '*.tsfile' 2>/dev/null | wc -l" | tr -dc '0-9'; }
mb_tsfile_cnt_all(){ local db=${1:-} h s=0 v; for h in "${DN[@]}"; do v=$(mb_tsfile_cnt "$h" "$db"); s=$(( s + ${v:-0} )); done; echo "$s"; }

# 等 memtable 排空（区域 memCost 降到阈值以下）或刷盘计数增加
mb_wait_flush(){ local before=$1 timeout=${2:-$FLUSH_WAIT_SEC} deadline=$(( $(date +%s) + ${2:-$FLUSH_WAIT_SEC} )) now mem
  while (( $(date +%s) < deadline )); do
    now=$(mb_flush_all); mem=$(mb_region_mem_all)
    log "  等刷盘: flush_total=$now (before=$before) regionMemCost=$mem"
    [ "${now:-0}" -gt "${before:-0}" ] && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# ④ 重启 / 强杀 / 等待
# ---------------------------------------------------------------------------
mb_restart_dn(){ local h=$1
  log "  --- 重启 DataNode $h ---"
  sshx "$h" "sudo $DB_DIR/sbin/stop-datanode.sh >/dev/null 2>&1 || true"
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 超时"
  sshx "$h" "source /etc/profile; nohup sudo $DB_DIR/sbin/start-datanode.sh >/dev/null 2>&1 &"
  wait_dn_state "$h" running "$RESTART_WAIT_SEC" || fail "DataNode $h 重启后未恢复 Running"
}
mb_kill9_dn(){ local h=$1
  log "  --- kill -9 DataNode $h（模拟异常宕机，验证 WAL 回放）---"
  sshx "$h" "sudo pkill -9 -f 'com\.timecho\.iotdb\.DataNode' >/dev/null 2>&1 || true"
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "kill -9 后 $h 仍显示 Running"
  sshx "$h" "source /etc/profile; nohup sudo $DB_DIR/sbin/start-datanode.sh >/dev/null 2>&1 &"
  wait_dn_state "$h" running "$RESTART_WAIT_SEC" || fail "DataNode $h kill -9 后未恢复 Running"
}

# 单点写入（用于"写到内存里但先不 flush"的场景），返回成功语句数
mb_write_to_node(){ local db=$1 dev=$2 rows=$3 b=${4:-1} node=$5
  mb_bulk_text "$db" "$dev" "$rows" "$b" "$MB_PAYLOAD_BYTES" "$node"; }

# 正证据打印（各用例 export MB_POSITIVE_EVIDENCE_FN 后由 check_logs 调用）
mb_evidence_alloc(){ local h; for h in "${DN[@]}"; do
  log "  [证据] $h 内存分配: $(mb_alloc_dump "$h" | tr '\n' ';' | cut -c1-600)"; done; }
mb_evidence_flush(){ log "  [证据] 刷盘累计（全 DN）= $(mb_flush_all)，活跃 memtable=$(mb_active_memtable "${DN[0]}")" ; }
mb_evidence_reject(){ log "  [证据] reject 进入次数（全 DN）= $(mb_reject_enter_all)，拒绝异常行数=$(mb_reject_exception_cnt "${DN[0]}")" ; }

# ---------------------------------------------------------------------------
# ⑤ 顺乱序分离存储 / 时间分区 的落盘布局观测
#   目录结构（实测）：data/datanode/data/{sequence,unsequence}/<database>/<regionId>/<timePartitionId>/*.tsfile
#   文档口径（顺乱序分离存储-需求分析）：
#     enable_separate_data=true  ⇒ 顺序数据落 sequence/，乱序数据落 unsequence/；
#     enable_separate_data=false ⇒ **数据只存储在乱序文件夹**（即全部落 unsequence/）。
# ---------------------------------------------------------------------------
mb_seq_tsfile_cnt(){ local h=$1 db=${2:-}
  sshx "$h" "sudo find $DB_DIR/data/datanode/data/sequence -path '*${db}*' -name '*.tsfile' 2>/dev/null | wc -l" | tr -dc '0-9'; }
mb_unseq_tsfile_cnt(){ local h=$1 db=${2:-}
  sshx "$h" "sudo find $DB_DIR/data/datanode/data/unsequence -path '*${db}*' -name '*.tsfile' 2>/dev/null | wc -l" | tr -dc '0-9'; }
mb_seq_all(){ local db=${1:-} h s=0 v; for h in "${DN[@]}"; do v=$(mb_seq_tsfile_cnt "$h" "$db"); s=$(( s + ${v:-0} )); done; echo "$s"; }
mb_unseq_all(){ local db=${1:-} h s=0 v; for h in "${DN[@]}"; do v=$(mb_unseq_tsfile_cnt "$h" "$db"); s=$(( s + ${v:-0} )); done; echo "$s"; }
# 某库在某个 DN 上的时间分区目录数（data/sequence/<db>/<region>/<partition>）
mb_partition_cnt(){ local h=$1 db=$2
  sshx "$h" "sudo find $DB_DIR/data/datanode/data/sequence/$db $DB_DIR/data/datanode/data/unsequence/$db -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l" | tr -dc '0-9'; }
mb_partition_all(){ local db=$1 h s=0 v; for h in "${DN[@]}"; do v=$(mb_partition_cnt "$h" "$db"); s=$(( s + ${v:-0} )); done; echo "$s"; }
# 某库在某 DN 上的 tsfile 总字节数（做"chunk 切分是否让文件变大"的证据）
mb_tsfile_bytes(){ local h=$1 db=$2
  sshx "$h" "sudo find $DB_DIR/data/datanode/data -path '*${db}*' -name '*.tsfile' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" | tr -dc '0-9'; }
mb_tsfile_bytes_all(){ local db=$1 h s=0 v; for h in "${DN[@]}"; do v=$(mb_tsfile_bytes "$h" "$db"); s=$(( s + ${v:-0} )); done; echo "$s"; }

# 时间分区内存信息的剔除证据（TimePartitionManager.degradeLastFlushTime）
mb_degrade_cnt(){ local h=$1
  sshx "$h" "grep -hcE 'degrade LastFlushTimeMap of old TimePartitionInfo' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'; }
mb_degrade_all(){ local h s=0 v; for h in "${DN[@]}"; do v=$(mb_degrade_cnt "$h"); s=$(( s + ${v:-0} )); done; echo "$s"; }

# ---------------------------------------------------------------------------
# ⑥ DN 实际堆大小（**不要硬编码**）
#   事实（已逐字节核对两版发布包）：
#     · RC8 与 RC9 的 `conf/datanode-env.sh` **完全相同**（md5 908b821c...）；
#     · 两版里 `#ON_HEAP_MEMORY="2G"` 都是**注释掉的** ⇒ 上游默认「按机器内存自动算」；
#     · 本环境 RC8 之所以是 20G，是**运维手工加了一行 `ON_HEAP_MEMORY="20G"`**，
#       不是版本默认值；RC9 新目录没带这行，于是走默认自动算（实测 `-Xmx12804M`）。
#   结论：堆大小是**部署时可变**的，既不是版本常量、也不是环境常量。
#   用例若把 20G 写死，换机器/换部署就立刻把"分配完全正确"误判成 35 条 FAIL（已踩过）。
#   ⇒ 一律从进程 cmdline 读 `-Xmx`，换算成字节。
# ---------------------------------------------------------------------------
mb_heap_bytes(){ local h=$1 pid mem unit
  pid=$(sshx "$h" "pgrep -f 'com\.timecho\.iotdb\.DataNode' | head -1")
  [ -z "$pid" ] && { echo 0; return; }
  mem=$(sshx "$h" "sudo tr '\0' '\n' < /proc/$pid/cmdline 2>/dev/null | grep -E '^-Xmx' | head -1")
  [ -z "$mem" ] && { echo 0; return; }
  mem=${mem#-Xmx}
  unit=$(printf '%s' "$mem" | tr -dc 'a-zA-Z' | tr 'a-z' 'A-Z')
  mem=$(printf '%s' "$mem" | tr -dc '0-9')
  case "$unit" in
    G) echo $(( mem * 1024 * 1024 * 1024 )) ;;
    M) echo $(( mem * 1024 * 1024 )) ;;
    K) echo $(( mem * 1024 )) ;;
    *) echo "${mem:-0}" ;;
  esac
}
mb_heap_gb(){ local b; b=$(mb_heap_bytes "$1"); awk -v x="$b" 'BEGIN{printf "%.2f", x/1024/1024/1024}'; }
# 把 5 个 DN 的堆打一行日志（便于报告里写清"本次跑的是什么堆"）
mb_heap_report(){ local h; for h in "${DN[@]}"; do log "  [$h] DN 堆 = $(mb_heap_gb "$h") GB (-Xmx)"; done; }
