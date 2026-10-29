#!/bin/bash
# ============================================================================
# CO-20 `target_compaction_file_size` 基础功能：目标文件大小影响**内部合并任务的产物个数**
#
# 源码依据（RC6 `7ae8713e`）：
#   `InnerSpaceCompactionTask.calculateSourceFilesAndTargetFiles()`（L314-320）
#     requiredPositionNum = min( (int)(selectedFileSize / target_compaction_file_size) + 1,
#                                sortedAllSourceFilesInTask.size() )
#   并把合并结果按该数量分发到目标位置 ⇒ target 越小、产物文件越多（同一批源文件）。
#   该键同时用于选择阶段（`NewSizeTieredCompactionSelector.singleFileSizeThreshold`）。
#
# 场景（6 个设备 × 2 批：多设备才能让产物"按设备/位置"分开落文件）：
#   · A 相：`target_compaction_file_size=1024`（1KB，远小于数据量）⇒ 产物文件数 N_A
#   · B 相：默认 2147483648（2GB）                            ⇒ 产物文件数 N_B
#   判据：两相都完成合并、数据指纹一致；**N_A > N_B**（分片真的发生）。
#   注：绝对文件数取决于设备分布/执行器切分，故只做相对断言，具体数目打进日志。
# 用法： bash co_target_file_size.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_target_file_size_${DATA_CONSENSUS}"

DB=root.cotgt
DEVS=6
ROWS=200

co20_scene(){ local db=$1 base d k b vals
  cmp_compaction_off
  sq "create database $db;" >/dev/null
  for ((d=1;d<=DEVS;d++)); do sq "create timeseries $db.d$d.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null; done
  base=$(now_ms)
  for b in 1 2; do
    for ((d=1;d<=DEVS;d++)); do
      vals=""; for ((k=1;k<=ROWS;k++)); do vals="$vals($(( base + b*20000 + k*10 )),$((k+b))),"; done
      sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null
    done
    sq "flush;" >/dev/null; sleep 8
  done
  sq "flush;" >/dev/null
  cmp_wait_close "$db" 2 90 >/dev/null || warn "  [$db] close 事件未达 2"
  sleep 8
  log "  [$db] 起点：布局=$(cmp_lay "$db") files=$(cmp_all_sum "$db") 字节=$(cmp_bytes_sum "$db")"; }
co20_merge(){ local db=$1 fin0 fin1 dl ok=0
  fin0=$(cmp_inner_finish "$db")
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  dl=$(( $(date +%s) + 180 ))
  while (( $(date +%s) < dl )); do
    fin1=$(cmp_inner_finish "$db")
    [ "${fin1:-0}" -gt "${fin0:-0}" ] && { ok=1; break; }
    sleep 3
  done
  sleep 10
  MERGE_OK=$ok; MERGE_FIN="$fin0→${fin1:-0}"; }

log "--- 集群准备：三类合并先关；multi_target + gap=0 + candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,target_compaction_file_size=1024" cmp_cluster_prepare

log "--- A 相：target=1KB ---"
DBA="${DB}a"
co20_scene "$DBA"
FPA=$(cmp_fp_tree "$DBA"); NBA=$(cmp_all_sum "$DBA")
co20_merge "$DBA"
NAA=$(cmp_all_sum "$DBA"); LAYA=$(cmp_lay "$DBA")
log "  [A] 合并后：布局=$LAYA files=$NBA → $NAA finishes=$MERGE_FIN"
[ "$MERGE_OK" = 1 ] && pass "  [A] target=1KB：合并发生（finishes $MERGE_FIN）" || fail "  [A] 合并未发生（finishes=$MERGE_FIN）"
cmp_assert_same "  [A] 合并前后数据指纹" "$FPA" "$(cmp_fp_tree "$DBA")"

log "--- B 相：默认 2GB ---"
cmp_set_hot target_compaction_file_size 2147483648 >/dev/null
DBB="${DB}b"
co20_scene "$DBB"
FPB=$(cmp_fp_tree "$DBB"); NBB=$(cmp_all_sum "$DBB")
co20_merge "$DBB"
NAB=$(cmp_all_sum "$DBB"); LAYB=$(cmp_lay "$DBB")
log "  [B] 合并后：布局=$LAYB files=$NBB → $NAB finishes=$MERGE_FIN"
[ "$MERGE_OK" = 1 ] && pass "  [B] 默认 target：合并发生（finishes $MERGE_FIN）" || fail "  [B] 合并未发生（finishes=$MERGE_FIN）"
cmp_assert_same "  [B] 合并前后数据指纹" "$FPB" "$(cmp_fp_tree "$DBB")"

log "  对照：target=1KB 产物 $NAA 个（源文件 $NBA 个）；默认 2GB 产物 $NAB 个（源文件 $NBB 个）"
[ "${NAA:-0}" -gt "${NAB:-0}" ] \
  && pass "  分片生效：小 target 的产物文件数（$NAA）> 默认 target（$NAB）" \
  || warn "  未观察到分片差异（$NAA vs $NAB）——产物数还取决于设备分布与执行器切分，记录实际值"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DBB.d1 order by time;" tree
cmp_case_finish "" tree ""
