#!/bin/bash
# MB-11 顺乱序分离存储（enable_separate_data）
#
# 需求依据：《V1.1.0.1-内存缓冲区-顺乱序分离存储-需求分析》
#   「打开 enable_separate_data 以后，数据在每个时间分区下将分为顺序和乱序两个目录存储，
#     否则数据只存储在乱序文件夹。」默认 true，**重启生效**。
#
# 实测落盘结构：data/datanode/data/{sequence,unsequence}/<database>/<regionId>/<partitionId>/*.tsfile
#
# 三阶段（同一份配置，只切 enable_separate_data，需重启）：
#   A 相 enable_separate_data=true  → 顺序写入必须落 sequence/
#   B 相 enable_separate_data=false → 顺序写入必须落 unsequence/（sequence/ 下不应再有该库新文件）
#   C 相 关掉后乱序写入 → 仍落 unsequence/，数据可查（回归：关掉后乱序路径不受影响）
# 判据：
#   ① 参数回读生效（true/false 与写入一致）；
#   ② A 相：该库 sequence/ 有 tsfile 且 unsequence/ 为 0（顺序数据不进乱序目录）；
#   ③ B 相：该库 sequence/ 为 0 且 unsequence/ 有 tsfile（"只存储乱序文件夹"）；
#   ④ 各相数据点数正确、flush 后仍正确；
#   ⑤ 收尾三件套（syncLag / 逐个停 DN 副本一致 / 日志异常）。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-11
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_flush

MB_MEM_PROPORTION="${MB_MEM_PROPORTION:-1:500:1:1:1:1}"
MB_FLUSH_PROPORTION="0.5"
MB_TIMED_FLUSH_SEQ="false"
MB_TIMED_FLUSH_UNSEQ="false"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_TIMED_FLUSH_SEQ MB_TIMED_FLUSH_UNSEQ

DBA=root.mb11a
DBB=root.mb11b
DBC=root.mb11c
ROWS=${MB11_ROWS:-400}
export EXTRA_CONF="enable_separate_data=true"

mb_cluster_prepare
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^enable_separate_data=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
  assert_eq "①$h enable_separate_data" "$got" "true"
done

log "--- A 相：separate=true，顺序写入 → 期望落 sequence/ ---"
mb_make_tree_db "$DBA" 1 int64
mb_bulk_int "$DBA" d1 "$ROWS" 1 >/dev/null
sq 'flush;' >/dev/null 2>&1
sleep 5
a_seq=$(mb_seq_all "$DBA"); a_unseq=$(mb_unseq_all "$DBA")
log "  A 相布局: sequence=$a_seq unsequence=$a_unseq"
assert_ge "②A 相 sequence/ 有 tsfile" "${a_seq:-0}" 1
assert_eq "②A 相 unsequence/ 为空（顺序数据不进乱序目录）" "${a_unseq:-0}" "0"
assert_eq "④A 相点数" "$(mb_count_all "$DBA")" "$ROWS"

# A 相已测完，先落 interim 结论（本用例要重启，总时长较长）
log "--- 中间落盘 interim 结论（A 相已完成）---"
write_result

log "--- B 相：separate=false（重启生效），顺序写入 → 期望只落 unsequence/ ---"
cluster_stop
cluster_clean
EXTRA_CONF="enable_separate_data=false"
export EXTRA_CONF
cluster_write_conf
cluster_start
wait_cluster_ready || fail "B 相集群未就绪"
for h in "${DN[@]}"; do
  got=$(sshx "$h" "grep -E '^enable_separate_data=' $DB_DIR/conf/iotdb-system.properties | tail -1 | cut -d= -f2-" | tr -d '\r')
  assert_eq "①$h enable_separate_data" "$got" "false"
done
mb_make_tree_db "$DBB" 1 int64
mb_bulk_int "$DBB" d1 "$ROWS" 1 >/dev/null
sq 'flush;' >/dev/null 2>&1
sleep 5
b_seq=$(mb_seq_all "$DBB"); b_unseq=$(mb_unseq_all "$DBB")
log "  B 相布局: sequence=$b_seq unsequence=$b_unseq"
assert_eq "③B 相 sequence/ 为空（关闭后不再分顺序目录）" "${b_seq:-0}" "0"
assert_ge "③B 相 unsequence/ 有 tsfile（只存储乱序文件夹）" "${b_unseq:-0}" 1
assert_eq "④B 相点数" "$(mb_count_all "$DBB")" "$ROWS"

# C 相与 B 相同配置（separate=false），因此**不需要再重启一次**：
#   直接在 B 相集群上建另一个库写"顺序 + 更早的乱序"数据即可。
#   首版把 C 相当成独立阶段又重启了一次，整条用例时长 ≈10min，正好落在本环境
#   "长跑 8~15 分钟易被 SIGKILL" 的窗口里（RC9 实测连续 3 次 NO_RESULT）。
log "--- C 相（复用 B 相集群）：separate=false 下写乱序数据，仍应落 unsequence/ 且可查 ---"
mb_make_tree_db "$DBC" 1 int64
mb_bulk_int "$DBC" d1 "$ROWS" 2 >/dev/null            # 先写较晚的一批
sq 'flush;' >/dev/null 2>&1                            # 建立 flushedTime
sleep 2
mb_bulk_int "$DBC" d1 "$ROWS" 1 >/dev/null            # 再写更早的 ⇒ 乱序
sq 'flush;' >/dev/null 2>&1
sleep 5
c_seq=$(mb_seq_all "$DBC"); c_unseq=$(mb_unseq_all "$DBC")
log "  C 相布局: sequence=$c_seq unsequence=$c_unseq"
assert_eq "④C 相乱序数据不落 sequence/（separate=false 只写乱序目录）" "${c_seq:-0}" "0"
assert_ge "④C 相 unsequence/ 有 tsfile" "${c_unseq:-0}" 1
assert_eq "④C 相点数（顺序+乱序共 $(( ROWS * 2 ))）" "$(mb_count_all "$DBC")" "$(( ROWS * 2 ))"

# 收尾一致性用"最全"的那个库（含顺+乱序两类数据）
mb_case_finish "$(mb_data_sql "$DBC")" tree
