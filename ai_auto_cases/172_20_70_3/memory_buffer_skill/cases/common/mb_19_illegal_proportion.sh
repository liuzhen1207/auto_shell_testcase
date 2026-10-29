#!/bin/bash
# MB-19 非法内存比例取值必须"回退默认值 + 打 WARN"，**不得让 DataNode 起不来**
#
# 需求依据：《V1.1.0.1-内存缓冲区-内存缓冲区-需求分析》配置表（各比例项的合法取值范围）
#           + 《技术设计》§写入内存管理（Write / Memtable / TimePartitionInfo / DevicePathCache /
#             BufferedArrays / WalBufferQueue 六个内存块都按比例派生）
#
# 预期（按 WARN 文案本身）：`storage_engine_memory_proportion` 出现 <=0 的分量时，
#   产品应打 WARN "The value of storage_engine_memory_proportion is illegal, use default value 8:2 ."
#   并**按默认值 8:2 继续启动**（WARN 里明确承诺了 "use default value"）。
#
# 本用例断言（这是回归门禁）：
#   ① 集群必须在 CLUSTER_READY_TIMEOUT 内起来（8/8 Running）；
#   ② 该 WARN 必须出现；
#   ③ 起来之后：Write/Memtable/DevicePathCache 等派生内存块必须非空，写入/刷盘/查询可用；
#   ④ 收尾三件套。
#
# ⚠️ 2026-10-21 实测（v20121rc8_1016_ebaf9da）**本用例预期 FAIL**，见 docs/FINDINGS.md F-07：
#   `storage_engine_memory_proportion=0:10` 时 DataNode 启动即崩：
#     Exception in thread "main" java.lang.ExceptionInInitializerError
#       at ...DataNodeDevicePathCache.getInstance(...)
#     Caused by: java.lang.NullPointerException: Cannot invoke
#       "org.apache.iotdb.commons.memory.MemoryManager.exactAllocate(...)" because the return value of
#       "org.apache.iotdb.db.conf.DataNodeMemoryConfig.getDevicePathCacheMemoryManager()" is null
#   根因：`DataNodeMemoryConfig.initStorageEngineAllocate()` 里 `<=0` 的守卫执行 `LOGGER.warn(...); return;`，
#   而**六个内存块的创建语句都在这个 return 之后**，因此 return 之后所有 manager 仍为 null。
#   修复方向：把 `return` 改成 `break`/`continue`（跳过该段解析，保留已算好的默认值），或在方法末尾统一兜底创建。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-19
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_alloc

DB=root.mb19
# 故意写成非法值：storage_engine 的分量 0 <= 0
MB_STORAGE_PROPORTION="0:10"
MB_MEM_PROPORTION="1:5:1:1:1:1"
export MB_STORAGE_PROPORTION MB_MEM_PROPORTION
export EXTRA_CONF=""

mb_cluster_prepare

# ① 集群必须起来
log "--- ① 非法 storage_engine_memory_proportion=0:10 后，集群是否仍可用 ---"
up=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running|ReadOnly')
log "  当前 Running/ReadOnly 节点数=$up（期望 >= 8）"
if [ "${up:-0}" -ge 8 ]; then
  pass "①集群仍可用（$up 个节点 Running/ReadOnly）"
else
  fail "①非法比例导致集群不可用（仅 $up 个节点在线）——DN 起不来"
  # 把崩溃栈抓进报告，便于直接定位
  for h in "${DN[@]}"; do
    st=$(sshx "$h" "sudo grep -cE 'Exception in thread .main.' /tmp/dn_${h}.start 2>/dev/null" | tr -dc '0-9')
    [ "${st:-0}" -gt 0 ] || st=$(sshx "$h" "sudo grep -cE 'ExceptionInInitializerError|NullPointerException' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')
    if [ "${st:-0}" -gt 0 ]; then
      log "  --- $h 启动崩溃栈（前 12 行）---"
      sshx "$h" "sudo grep -E 'Exception in thread|^\\s+at |Caused by' /tmp/dn_${h}.start 2>/dev/null | head -12 | cut -c1-240" >>"$OUT" 2>&1 || true
      sshx "$h" "sudo grep -E 'Exception in thread|^\\s+at |Caused by' /tmp/dn_${h}.start 2>/dev/null | head -8 | cut -c1-240"
    fi
  done
fi

# ② WARN 必须打出
for h in "${DN[@]}"; do
  n=$(mb_warn_cnt "$h" 'storage_engine_memory_proportion is illegal')
  if [ "${n:-0}" -ge 1 ]; then
    pass "②$h 打出 storage_engine 非法回退告警（$n 条）"
  else
    # 节点没起来就没有日志，这本身就是 ① 的失败，避免重复记账只记 warn
    warn "②$h 未见 storage_engine 非法回退告警（若节点未启动则属 ① 的连带结果）"
  fi
done

if [ "${up:-0}" -ge 8 ]; then
  # ③ 派生内存块非空 + 功能可用
  for h in "${DN[@]}"; do
    w=$(mb_alloc_log "$h" Write)
    assert_ge "③$h Write 分配为正（回退到默认 8:2 后非 0）" "${w:-0}" 1
    d=$(mb_actual "$h" 'StorageEngine-Write-Memtable-DevicePathCache')
    log "  [$h] DevicePathCache 实际占用=$d（能采样到说明 manager 非 null）"
  done
  log "--- ③ 功能冒烟 ---"
  mb_make_tree_db "$DB" 2 int64
  ok=$(mb_bulk_int "$DB" d1 2000 1); ok=${ok%% *}
  assert_ge "写入语句成功数" "${ok:-0}" 1
  sq 'flush;' >/dev/null 2>&1
  sleep 3
  assert_eq "写入点数可查" "$(mb_count_all "$DB")" "2000"
  assert_ge "有 TsFile 落盘" "$(mb_tsfile_cnt_all "$DB")" 1
  mb_case_finish "$(mb_data_sql "$DB")" tree
else
  # 集群起不来：跳过功能与收尾一致性（做不了），直接写结论
  warn "集群不可用，跳过功能冒烟与副本一致性检查（这是 ① 的直接后果）"
  if [ "$fail_flag" -gt 0 ]; then backup_logs; fi
  [ "${KEEP_DATA:-0}" = "1" ] || cluster_stop
  write_result
fi
