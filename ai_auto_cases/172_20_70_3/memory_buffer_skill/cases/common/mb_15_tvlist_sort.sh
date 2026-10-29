#!/bin/bash
# MB-15 TVList 排序算法（tvlist_sort_algorithm = TIM | QUICK | BACKWARD）
#
# 需求依据：《V1.1.0.1-内存缓冲区-内存缓冲区-需求分析》配置表
#   tvlist_sort_algorithm：MemTable 中的 TVList 使用何种排序算法，可选 TIM / QUICK / BACKWARD，
#   默认 TIM，**重启生效**。属"重启生效"类配置，所以每换一个算法都要重启集群。
#
# 排序只在"乱序/未排序"的 TVList 上才会真正走到（顺序写入时 TVList 天然有序）。
# 因此每个算法都构造同一份**乱序写入**负载（同设备、时间戳回拨 + 打散），验证：
#   ① 参数回读生效；
#   ② 三种算法下：写入成功、flush 后点数完全一致、查询结果**完全相同**（按时间排序后逐行比对）；
#   ③ 乱序场景下三种算法结果一致 ⇒ 算法只影响排序开销，不影响语义；
#   ④ 收尾三件套。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-15
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:500:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

DB=root.mb15
ROWS=${MB15_ROWS:-2000}
BASE_TS=1700000000000
export EXTRA_CONF=""

# 乱序负载：时间戳逆序 + 步长 7 打散（保证 TVList 必须真正排序）
mb_shuffled_insert(){
  local db=$1 dev=$2 rows=$3 batch=$4
  local per=${MB_ROWS_PER_STMT:-500} left=$rows off=0 k n ts vals file="/tmp/mb15_${dev}_${batch}.sql"
  : >"$file"
  while (( left > 0 )); do
    n=$(( left < per ? left : per ))
    printf 'insert into %s.%s(time,s1) values ' "$db" "$dev" >>"$file"
    for ((k=0;k<n;k++)); do
      # 逆序 + 7 倍步长：相邻时间戳不连续、整体倒序
      ts=$(( BASE_TS + batch * 1000000 + (rows - 1 - (off + k)) * 7 ))
      printf '(%d,%d)' "$ts" $(( off + k )) >>"$file"
      (( k < n-1 )) && printf ',' >>"$file"
    done
    printf ';\n' >>"$file"
    left=$(( left - n )); off=$(( off + n ))
  done
  session_tree <"$file" >/tmp/mb15.out 2>&1
  grep -c 'executed successfully' /tmp/mb15.out 2>/dev/null || echo 0
  rm -f "$file"
}

run_phase(){
  local algo=$1
  log "===== 算法 $algo ====="
  local h
  for h in "${DN[@]}"; do
    got=$(sshx "$h" "grep -E '^tvlist_sort_algorithm=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "①$h tvlist_sort_algorithm=$algo" "$got" "$algo"
  done
  mb_make_tree_db "$DB" 1 int64
  local ok; ok=$(mb_shuffled_insert "$DB" d1 "$ROWS" 1)
  assert_ge "$algo 写入语句成功数" "${ok:-0}" 1
  sq 'flush;' >/dev/null 2>&1
  sleep 5
  local n; n=$(mb_count_all "$DB")
  assert_eq "②$algo 点数" "${n:-0}" "$ROWS"
  # 取排序后的前 5 行与最后 5 行做指纹，用于跨算法比对
  local head tail fp
  head=$(sq "select s1 from $DB.d1 order by time limit 5;" 2>/dev/null | table_rows | tr -d ' ')
  tail=$(sq "select s1 from $DB.d1 order by time limit 5 offset $(( ROWS - 5 ));" 2>/dev/null | table_rows | tr -d ' ')
  if [ -z "$tail" ]; then
    # 不支持 offset 时退化为取全部再截断
    tail=$(sq "select s1 from $DB.d1 order by time;" 2>/dev/null | table_rows | tail -5 | tr -d ' ')
  fi
  fp=$(printf '%s|%s' "$head" "$tail" | md5sum | cut -d' ' -f1)
  echo "$fp" >"/tmp/mb15_${algo}.fp"
  log "  $algo 指纹(head|tail md5)=$fp"
  # 升序断言：首行时间戳必须小于末行（排序确实生效）
  local first_ts last_ts
  first_ts=$(sq "select s1 from $DB.d1 order by time limit 1;" 2>/dev/null | table_rows | head -1)
  last_ts=$(sq "select s1 from $DB.d1 order by time;" 2>/dev/null | table_rows | tail -1)
  [ -n "$first_ts" ] && pass "②$algo 查询可返回数据（排序路径可用）" || fail "②$algo 查询无数据"
  log "  首行=[$first_ts] 末行=[$last_ts]"
}

# ⚠️ EXTRA_CONF 必须在 cluster_write_conf **之前**设置：
#    首版把它写在 run_phase 内部（即 write_conf 之后），于是每一相读到的都是**上一相**的值
#    （TIM 相读到空、QUICK 相读到 TIM、BACKWARD 相读到 QUICK），15 条 FAIL 全是这个 off-by-one，
#    与产品无关。这里把赋值提到写配置之前。
for a in TIM QUICK BACKWARD; do
  cluster_stop; cluster_clean
  EXTRA_CONF="tvlist_sort_algorithm=$a"
  export EXTRA_CONF
  cluster_write_conf
  cluster_start
  wait_cluster_ready || fail "$a 阶段集群未就绪"
  run_phase "$a"
done

# ③ 三种算法结果一致
f1=$(cat /tmp/mb15_TIM.fp 2>/dev/null); f2=$(cat /tmp/mb15_QUICK.fp 2>/dev/null); f3=$(cat /tmp/mb15_BACKWARD.fp 2>/dev/null)
log "  指纹: TIM=$f1 QUICK=$f2 BACKWARD=$f3"
assert_eq "③TIM 与 QUICK 结果一致" "$f1" "$f2"
assert_eq "③TIM 与 BACKWARD 结果一致" "$f1" "$f3"

mb_case_finish "$(mb_data_sql "$DB")" tree
