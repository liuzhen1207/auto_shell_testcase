#!/bin/bash
# MB-16 flush_thread_count + primitive_array_size（重启生效）
#
# 需求依据：《内存缓冲区-需求分析》配置表
#   flush_thread_count：用于 Flush 的线程数，不大于 0 时视为 CPU 核数，默认 0，**重启生效**；
#   primitive_array_size：TVList 中存储数据的数组的单个大小，默认 64，**重启生效**。
#
# 做法：两相（各需重启）
#   A 相 flush_thread_count=0（自动=CPU 核数）、primitive_array_size=64（默认）
#   B 相 flush_thread_count=1、primitive_array_size=16（放大扩容频次，逼出边界问题）
# 判据：
#   ① 参数回读生效；
#   ② 两相都能正常写入 + flush + 查询，点数完全一致（说明线程数/数组大小不影响语义）；
#   ③ B 相刷盘确实发生（flush 计数增加）；
#   ④ 大数据量下（多点 + 多设备）不出现异常日志（数组扩容路径）；
#   ⑤ 收尾三件套。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-16
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:300:1:1:1:1"
MB_FLUSH_PROPORTION="0.4"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION
DB=root.mb16
DEVS=${MB16_DEVS:-4}
ROWS=${MB16_ROWS:-1500}

phase(){
  local tag=$1 devs=$2 rows=$3
  log "===== $tag ====="
  local h
  for h in "${DN[@]}"; do
    local n p
    n=$(sshx "$h" "grep -E '^flush_thread_count=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    p=$(sshx "$h" "grep -E '^primitive_array_size=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "①$h flush_thread_count" "$n" "$FLUSH_THREADS"
    assert_eq "①$h primitive_array_size" "$p" "$PRIM_ARRAY"
  done
  mb_make_tree_db "$DB" "$devs" int64
  local f0; f0=$(mb_flush_all)
  local d ok tot_ok=0
  for ((d=1; d<=devs; d++)); do
    ok=$(mb_bulk_int "$DB" "d$d" "$rows" 1); ok=${ok%% *}
    tot_ok=$(( tot_ok + ${ok:-0} ))
  done
  assert_ge "$tag 写入语句成功数" "$tot_ok" 1
  sq 'flush;' >/dev/null 2>&1
  if mb_wait_flush "$f0" 180; then pass "$tag 刷盘发生"; else fail "$tag 未观察到刷盘"; fi
  sleep 3
  local n; n=$(mb_count_all "$DB")
  assert_eq "$tag 点数" "${n:-0}" "$(( devs * rows ))"
}

# A 相：默认（线程自动、数组 64）
FLUSH_THREADS="0"; PRIM_ARRAY="64"
export EXTRA_CONF="flush_thread_count=$FLUSH_THREADS,primitive_array_size=$PRIM_ARRAY"
mb_cluster_prepare
phase "A-默认(线程0/数组64)" "$DEVS" "$ROWS"

# B 相：单线程 + 小数组
FLUSH_THREADS="1"; PRIM_ARRAY="16"
export EXTRA_CONF="flush_thread_count=$FLUSH_THREADS,primitive_array_size=$PRIM_ARRAY"
cluster_stop; cluster_clean; cluster_write_conf; cluster_start
wait_cluster_ready || fail "B 相集群未就绪"
phase "B-单线程(线程1/数组16)" "$DEVS" "$ROWS"

mb_case_finish "$(mb_data_sql "$DB")" tree
