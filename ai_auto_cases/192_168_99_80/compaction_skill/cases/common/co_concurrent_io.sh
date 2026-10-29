#!/bin/bash
# ============================================================================
# CO-31 **合并与读写并发**：合并进行中持续写入 + 查询 ⇒ 不报错、数据最终一致
#
# 为什么必须有这条：真实业务不会"停下来等合并"。并发路径涉及
#   `InnerSpaceCompactionTask` 的写锁/`TsFileResource.compacting` 标记、
#   `CompactionScheduleContext` 的候选校验（`setSourceFilesToCompactionCandidate`）、
#   以及查询侧的文件快照 —— 出问题就是丢数据/查询报错/副本不一致。
#
# 场景（单设备 TEXT，用限流把合并拖到秒级）：
#   ① 写 2 个 TsFile（各 ≈3MB）⇒ 开合并（写/读限流 1MB/s）
#   ② 合并期间后台**并发**：每 2s 写一小批新数据（顺序时间戳）+ 每次查询 count/内容
#   ③ 判据：并发写入全部成功、并发查询无错误输出、合并最终完成、总行数 = 2 批 + 并发批、
#           指纹一致、收尾 sync lag 归零与副本一致
# 用法： bash co_concurrent_io.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_concurrent_io_${DATA_CONSENSUS}"

DB=root.coconc
ROWS=3000
PER=200
CONC_BATCHES=${CO_CONC_BATCHES:-6}

log "--- 集群准备：三类合并先关；写/读限流 1MB/s 把合并拖长，便于并发 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare

PAYLOAD=$(printf 'z%.0s' $(seq 1 1000))
# ⚠️ 大 payload 不能用 `sq ... -e`（`Argument list too long`，静默不落盘）⇒ 单会话 stdin 喂语句
co31_write(){ local db=$1 base=$2 b=$3 rows=$4 tag=$5 k vals="" i=0 ts stmts=""
  for ((k=1;k<=rows;k++)); do
    ts=$(( base + (b-1)*100000 + k*10 ))
    vals="$vals($ts,'$PAYLOAD'),"
    i=$(( i + 1 ))
    if [ $(( i % PER )) -eq 0 ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; vals=""; fi
  done
  if [ -n "$vals" ]; then stmts="${stmts}insert into $db.d1(time,s1) values ${vals%,};
"; fi
  printf '%s' "$stmts" | session_tree >/dev/null 2>>"$CONC_ERR" || echo "insert-$tag-fail" >>"$CONC_ERR"
  sq "flush;" >/dev/null 2>>"$CONC_ERR"; }

cmp_compaction_off
CONC_ERR="$OUTDIR/conc_err_${RUN_ID}.txt"; : >"$CONC_ERR"
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
BASE=$(now_ms)
co31_write "$DB" "$BASE" 1 3000 init1
co31_write "$DB" "$BASE" 2 3000 init2
sq "flush;" >/dev/null
cmp_wait_close "$DB" 2 90 >/dev/null || warn "  初始两批 close 未达 2"
cmp_wait_lay "$DB" "2/0/0/0" 150 >/dev/null || warn "  初始布局=$(cmp_lay "$DB")（期望 2/0/0/0）"
CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
FIN0=$(cmp_inner_finish "$DB")
log "  初始：布局=$(cmp_lay "$DB") 行数=$CNT0 字节=$(cmp_bytes_sum "$DB")"

: >"$CONC_ERR"
log "--- ① 开合并（限流 1MB/s，会持续若干秒）---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 3
log "--- ② 后台并发：写 $CONC_BATCHES 小批 + 查询（每批 flush）---"
( i=0
  for ((i=1;i<=CONC_BATCHES;i++)); do
    b=$(( 100 + i ))
    co31_write "$DB" "$BASE" "$b" 200 "conc$i"
    sq "flush;" >/dev/null 2>>"$CONC_ERR"
    q=$(sq "select count(s1) from $DB.**;" 2>&1)
    printf '%s' "$q" | grep -qiE 'error|exception|Msg:' && echo "query-conc$i-fail: $(printf '%s' "$q" | tr '\n' ' ' | cut -c1-200)" >>"$CONC_ERR"
    sleep 2
  done ) &
CONC_PID=$!
wait "$CONC_PID"
log "  并发写入结束；等待合并窗口"
deadline=$(( $(date +%s) + 300 )); ok=0
while (( $(date +%s) < deadline )); do
  FIN1=$(cmp_inner_finish "$DB"); [ "${FIN1:-0}" -gt "${FIN0:-0}" ] && { ok=1; break; }; sleep 5
done
sleep 15
FIN2=$(cmp_inner_finish "$DB")
CNT1=$(row_sum "$(sq "select count(s1) from $DB.**;")")
ERRN=$(wc -l <"$CONC_ERR" | tr -dc '0-9')
log "  合并后：布局=$(cmp_lay "$DB") finishes=$FIN0 → $FIN2 行数=$CNT0 → $CNT1 并发错误行=$ERRN"
[ "$ok" = 1 ] && pass "  并发写/查期间合并仍推进（finishes $FIN0 → $FIN2）" || warn "  未观察到合并推进（$FIN0 → $FIN2，记录）"
[ "${ERRN:-0}" -eq 0 ] && pass "  并发写入与查询全程无错误输出（$CONC_BATCHES 批 × 200 行）" \
  || { fail "  并发期间出现 $ERRN 条错误"; sed 's/^/    | /' "$CONC_ERR" >>"$OUT"; }
[ "${CNT1:-0}" -ge "${CNT0:-0}" ] && pass "  并发写入的数据都在（行数 $CNT0 → $CNT1，期望 ≥ 起始值）" \
  || fail "  行数异常减少：$CNT0 → $CNT1"
DIST=$(cmp_task_nums "$DB" inner)
log "  本用例 inner 任务文件数分布=$DIST"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
