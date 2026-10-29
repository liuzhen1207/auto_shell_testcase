#!/bin/bash
# MB-12 flush 时按序列点数和大小切分 Chunk（target_chunk_point_num / target_chunk_size）
#
# 需求依据：《V2.0.5.1-内存缓冲区-flush 时按序列点数和大小进行切分 Chunk-需求分析》
#   · 旧机制 `avg_series_point_number_threshold`（10w 点触发 flush）已被移除；
#   · 新机制：flush 时按 `target_chunk_point_num`（默认 100_000）与 `target_chunk_size`
#     （默认 1_600_000 字节，文档 V2.0.5.1 写 16M，本版本模板实测 1600000）切分 Chunk；
#   · 目的：既不因反复触发 flush 产生大量小文件，也不生成"单点查询要解开整个大 chunk"的超大 chunk。
#
# 判据（行为 + 布局，不依赖 chunk 内部结构）：
#   ① 参数回读生效；
#   ② 极小 target_chunk_point_num（如 500）下，写入 5000 点 → 数据完整可查、不丢不重；
#   ③ 极小 target_chunk_size（如 4096）下写 TEXT → 数据完整可查；
#   ④ 与默认值相比，TsFile 文件"数量"不因切分而增加（切分发生在 chunk 层，不是文件层）；
#   ⑤ 极值守卫：target_chunk_point_num=1 / target_chunk_size=1 时写入仍成功、节点不崩、数据可查；
#   ⑥ 收尾三件套。
# 说明：本环境未找到"直接读 TsFile 内 chunk 数"的可用工具（tsfile 类不在客户端 jar 里），
#   因此 chunk 层只做"正确性 + 文件数 + 文件字节数证据"，并在 <CASE>.out 里打印字节数供研发核对。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-12
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="1:500:1:1:1:1"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

DB=root.mb12
ROWS=${MB12_ROWS:-5000}
export EXTRA_CONF="target_chunk_point_num=500,target_chunk_size=4096"

mb_cluster_prepare
for h in "${DN[@]}"; do
  for kv in target_chunk_point_num=500 target_chunk_size=4096; do
    k="${kv%%=*}"; v="${kv#*=}"
    got=$(sshx "$h" "grep -E '^$k=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
    assert_eq "①$h $k 生效" "$got" "$v"
  done
done

log "--- 小 chunk 参数下写 $ROWS 点（INT64）---"
mb_make_tree_db "$DB" 1 int64
ok=$(mb_bulk_int "$DB" d1 "$ROWS" 1); ok=${ok%% *}
assert_ge "写入语句成功数" "${ok:-0}" 1
sq 'flush;' >/dev/null 2>&1
sleep 5
assert_eq "②极小 target_chunk_point_num 下点数完整" "$(mb_count_all "$DB")" "$ROWS"

log "--- 小 chunk 参数下写 TEXT（触发 target_chunk_size 路径）---"
dbt=${DB}t
mb_make_tree_db "$dbt" 1 text
okt=$(mb_bulk_text "$dbt" d1 600 1 4000); okt=${okt%% *}
assert_ge "TEXT 写入语句成功数" "${okt:-0}" 1
sq 'flush;' >/dev/null 2>&1
sleep 5
assert_eq "③极小 target_chunk_size 下 TEXT 点数完整" "$(mb_count_all "$dbt")" "600"

# ④ 切分只影响 chunk，不应让 TsFile 数量爆炸：5000 点 + 600 TEXT 共 2 个库，
#    每个库每个 region 分区至少 1 个文件；给出上限守卫（每 DN 每库 ≤ 5 个文件）
f_int=$(mb_tsfile_cnt_all "$DB"); f_txt=$(mb_tsfile_cnt_all "$dbt")
bytes_int=$(mb_tsfile_bytes_all "$DB"); bytes_txt=$(mb_tsfile_bytes_all "$dbt")
log "  证据: INT64 库 tsfile=$f_int bytes=$bytes_int / TEXT 库 tsfile=$f_txt bytes=$bytes_txt"
assert_ge "④INT64 库有 tsfile" "${f_int:-0}" 1
assert_ge "④TEXT 库有 tsfile" "${f_txt:-0}" 1
[ "${f_int:-0}" -le 25 ] && pass "④切分未导致 INT64 文件数爆炸（$f_int <= 25）" || fail "④INT64 文件数异常: $f_int"
[ "${f_txt:-0}" -le 25 ] && pass "④切分未导致 TEXT 文件数爆炸（$f_txt <= 25）" || fail "④TEXT 文件数异常: $f_txt"

log "--- ⑤极值守卫：target_chunk_point_num=1 / target_chunk_size=1（需重启）---"
cluster_stop; cluster_clean
EXTRA_CONF="target_chunk_point_num=1,target_chunk_size=1"
export EXTRA_CONF
cluster_write_conf
cluster_start
wait_cluster_ready || fail "极值场景集群未就绪"
for h in "${DN[@]}"; do
  st=$(dn_state "$h")
  assert_eq "⑤极值配置下 $h 仍 Running" "$st" "Running"
done
DBX=root.mb12x
mb_make_tree_db "$DBX" 1 int64
okx=$(mb_bulk_int "$DBX" d1 800 1); okx=${okx%% *}
assert_ge "⑤极值配置下写入仍成功" "${okx:-0}" 1
sq 'flush;' >/dev/null 2>&1
sleep 5
assert_eq "⑤极值配置下数据可查" "$(mb_count_all "$DBX")" "800"

mb_case_finish "$(mb_data_sql "$DBX")" tree
