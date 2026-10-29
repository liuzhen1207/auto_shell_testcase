#!/bin/bash
# ============================================================================
# W-06 DN 正常下线期写入 + 恢复（树模型；库名 root.waldn）
# ----------------------------------------------------------------------------
# 目标（cases/cases.tsv W-06）：停 1 个 DataNode（**正常 stop**，与 W-04/W-05 的 kill -9 掉电相对照）
#   → 下线期间继续写入（RF=3 ⇒ 2/3 副本仍应接受写入）→ 拉起该 DataNode
#   → 该副本数据补齐、三副本一致（走"共识补偿 + 本机 WAL 重放"两条链路）
#   → WAL 面记录该 DN 停机前 / 恢复后的 WAL 文件数与字节（**证据，不是判据**）。
#
# 需求依据（docs/req_sources/design_extract.md）：
#   · §1.3「在 IoTConsensus 中，每个 DataRegion 拥有一个 WAL Node」⇒ 库 root.waldn 的 DataRegion
#     在三个 DN 上各有一个 WALNode；被停掉的那个副本重启后，必须靠**自己的 WAL** 补上
#     "停机前已写入但未刷盘"的那部分（§1.1：WAL 是 redo-only，只重放、不回滚）。
#   · §4.3「重启恢复」：恢复粒度为 WAL Node —— 读 checkpoint 恢复未刷盘 MemTable →
#     读 WAL Entry 分给 0 层未封口 TsFile 的 UnsealedTsFileRecoverPerformer → 删除该 WALNode 下所有文件。
#   · §4.4：文档**没有**给出任何"恢复完成"的信号（无日志关键字/无 metrics/无 SQL）
#     ⇒ 本用例用"轮询到数据可见 + sync lag 归零"代替，**不假设重启后立刻可见**。
#   · 「DN 下线期是否仍可写」「下线期写入的数据如何补偿到重启副本」三份文档**均未提及**
#     ⇒ 只按"数据面必须一致、下线期写入必须成功"判 FAIL；补偿链路内部过程只打证据。
#
# 判据（FAIL 只来自数据面 / 场景有效性）：
#   1) 场景有效性（硬）：DataNode 进程真的停了、又真的起来了；集群级 WAL 文件数 > 0；
#      写入行数达标（写入失败 ⇒ 数据行数不足 ⇒ FAIL，不许静默通过）；
#   2) 下线期写入：RF=3、1 副本下线时 insert 仍应成功、行数达标（不达标 = FAIL）；
#   3) 恢复后数据一致：全库 count/sum 指纹与停机前完全一致；逐副本比对（cmp_assert_nodes_same）；
#   4) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无 NPE·OOM·越界等异常；
#   5) WAL 文件数 · 字节数 · 耗时 ⇒ 只打印作证据（文档未给阈值，绝对值不可判定 ⇒ 不判 FAIL）。
#
# 用法： bash cases/common/wal_recovery_dn_down.sh [--consensus IoTConsensus|IoTConsensusV2]
#
#   ⚠ **本条未实跑**（写就时 99.80 正在跑合并长回归，禁止任何集群动作；本用例会停/起 DataNode，
#     正属于"任何集群动作"）。仅保证 `bash -n` 与 tools/selftest.sh 的静态检查通过。
#
# watch list（首跑前逐条确认，3~5 条）：
#   ① `wal_stop_dn` 走 `$DB_DIR/sbin/stop-datanode.sh -f`（**正常 stop**）：确认该脚本在本环境存在；
#      若不存在，"正常下线"这一相根本走不到，会先在 dn_state 轮询上白耗 DN_DOWN_WAIT_SEC。
#   ② 停机前 `wal_file_cnt "$VICTIM"` 可能本来就是 0（该副本的 WAL 已被 checkpoint 清掉）：
#      故**只有集群级 WAL 文件数 > 0 是硬断言**，单副本为 0 只 WARN + 打印逐副本证据。
#   ③ 本用例强制 VICTIM=DN[1]：`sq` 走 QDN=DN[0]，若拿 DN[0] 当 victim，停机期所有 sq/wait_scalar_tree
#      都会打到已下线节点（CLI 连不上）⇒ 用例假失败。
#   ④ 若"下线期写入"本身报错，先确认是不是 2/3 副本下 Leader 尚未切换完（本用例已在写入前 sleep 数秒）；
#      若稳定报错则**是 FAIL 不是跳过**——RF=3 下 1 副本下线不允许影响写入。
#   ⑤ WAL 文件数"恢复后"可能比"停机前"更多（重放/轮转会新建文件）⇒ 不写死变化方向，只记录。
#
# ---------------------------------------------------------------------------
# 判据速查（读代码先看这里：FAIL 只可能来自 §A 场景有效性 与 §B 数据面）
#   §A 场景有效性（fail "场景无效：…"，不许静默跳过）：
#        · DN 少于 2 个（无法做"其余副本仍在线"的场景）
#        · victim 停机前找不到 DataNode 进程 / 停机后进程仍在 / 未真正 Running 回来
#        · 写入后行数 ≠ 设备数 × 每设备行数（批1）或 ≠ 2 ×（批2 后）
#        · 集群级 WAL 文件数 = 0（连 WAL 目录都没识别出来，谈不上验证 WAL 路径）
#   §B 数据面（唯一的"产品问题"判据）：
#        · 停机/恢复前后全库 count/sum 指纹不一致
#        · 恢复后经 victim 自己查询（轮询 RESTART_WIN 秒）行数达不到
#        · 逐副本 `d1` 全序列结果不一致（cmp_assert_nodes_same）
#   §C 只 WARN / 只记录（绝不 FAIL）：
#        · victim 单副本 WAL 文件数 = 0（可能已被 checkpoint 清理）
#        · WAL 文件数/字节的增减方向、写入耗时、指标绝对值
#   §D 与相邻用例的边界（避免重复覆盖）：
#        · W-04 / W-05 用 **kill -9** 判"掉电后 WAL 必须完整重放"；本条用**正常 stop**，
#          判"计划内下线期间写入不中断 + 拉起后该副本补齐"，两者互补而不是重复。
#        · W-14 判"无效 WAL 被清理"；本条完全不碰清理，只把文件数当证据记录。
#        · W-07 判"元数据变更后 kill -9 全部 DN"；本条只动一个 DN 且不动 DDL。
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_recovery_dn_down_${DATA_CONSENSUS}"

DB=root.waldn
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
WIN=${WAL_WIN_SEC:-120}
RESTART_WIN=${WAL_REPLAY_WIN_SEC:-300}

# --- victim 选择与规模基线 -------------------------------------------------
if [ "${#DN[@]}" -lt 2 ]; then
  fail "场景无效：DN 少于 2 个（本用例需要‘其余副本仍在线’才能验证下线期写入）"
fi
VICTIM="${DN[1]:-}"
[ -n "$VICTIM" ] || VICTIM="${DN[0]}"

# 两批数据的时间戳基准：批 2 明显晚于批 1（避免落到同一时间分区、也便于区分"下线期写入的那一段"）
BASE=$(( ($(date +%s) - 3600) * 1000 ))
BASE2=$(( BASE + 1000000 ))
CNT1=$(( DEVS * ROWS ))
CNT2=$(( DEVS * ROWS * 2 ))

# ---------------------------------------------------------------------------
# 本地辅助（只在本用例内使用；不写进 lib/，避免影响其它 skill）
# ---------------------------------------------------------------------------
# DataNode 进程数（比 `show cluster` 更直接地证明"节点真的停/起了"）
#   pid 由 lib/wal_ext.sh 的 `wal_dn_pid` 精确识别（/proc/*/cmdline，只认 java + DataNode），
#   再用 `kill -0` 复核；**不要**用 `pgrep -c -f com.timecho.iotdb.DataNode`——它会把远端
#   `bash -c` 包装 shell 一起数进去 ⇒ DN 已退出时计数仍 ≥1 ⇒ "进程仍在"的假 FAIL。
w06_proc_cnt(){ local p
  p=$(wal_dn_pid "$1"); [ -n "$p" ] || { echo 0; return 0; }
  wal_dn_alive "$1" "$p" && echo 1 || echo 0; }

# 写一批数据（多值 INSERT，500 行/语句）——**故意不 flush**：
#   这批数据要么留在 WAL 里（停机副本重启后重放），要么已被自动刷盘 ⇒ 两种都必须一条不少。
w06_write_batch(){ local db=$1 base=$2 b=$3 d k ts vals
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=0; k<ROWS; k++)); do
      ts=$(( base + k * 10 ))
      vals="$vals($ts,$(( k + b ))),"
      if [ $(( (k + 1) % 500 )) -eq 0 ]; then
        sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
          || warn "  批$b 设备$d 第 $((k+1)) 点写入返回非空（行数断言会兜底）"
        vals=""
      fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
      || warn "  批$b 设备$d 尾批写入返回非空"; }
  done
  log "  批$b 写入完成（基准 $base，每设备 $ROWS 点，**未 flush**：这部分要靠 WAL 保证）"
}

# 轮询：经**指定节点**查询标量达到期望（用于"重启副本自己也能看到数据"的判据）
w06_wait_cnt_on(){ local h=$1 sql=$2 want=$3 win=$4 label=$5 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(scalar "$(sq_node "$h" "$sql")")
    got=${got:-0}
    if [ "$got" = "$want" ]; then pass "$label：经 $h = $got"; return 0; fi
    sleep 5
  done
  fail "$label：经 $h 实际=[$got] 期望=[$want]（等 ${win}s 未达到）"
  return 1; }

# 全库总行数（select count(s1) from <db>.** 每序列一列 ⇒ 用 row_sum 求和）
w06_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }

log "=== W-06 目标：正常下线 $VICTIM 期间写入，再拉起并核对三副本 ==="
log "  库=$DB 设备=$DEVS 每设备行数=$ROWS（批1 + 下线期批2） 期望总行数=$CNT2 victim=$VICTIM"
log "  consensus=${CONSENSUS_CLASS##*.} DATA_RF=$DATA_RF"

# ---------------------------------------------------------------------------
# ① 集群准备：WAL 默认参数（ASYNC、压缩开、buffer 32M、max_wal_nodes_num=0）
# ---------------------------------------------------------------------------
log "--- ① 集群准备（EXTRA_CONF 前缀环境变量单条命令）---"
EXTRA_CONF="$WAL_EXTRA_DEFAULT" cmp_cluster_prepare
log "  生效值抽检（${DN[0]}）：wal_mode=$(wal_eff "${DN[0]}" wal_mode) buffer=$(wal_eff "${DN[0]}" wal_buffer_size_in_byte) 阈值=$(wal_eff "${DN[0]}" wal_file_size_threshold_in_byte)"

# ---------------------------------------------------------------------------
# ② 批 1：三副本全在线时写入（不 flush ⇒ 这批数据必须进 WAL）
# ---------------------------------------------------------------------------
log "--- ② 批1：三副本全在线写入（未 flush）---"
cmp_make_tree_db "$DB" "$DEVS"
w06_write_batch "$DB" "$BASE" 1
wait_scalar_tree "select count(s1) from $DB.d1;" "$ROWS" 90 "批1 后 d1 可见行数"
TOT1=$(w06_total)
assert_eq "批1 后全库总行数" "$TOT1" "$CNT1"

# 场景有效性：WAL 目录必须真的有 .wal 文件（没有 WAL 就谈不上 WAL 恢复）
WALF0=$(wal_sum_over_dn wal_file_cnt)
WALB0=$(wal_sum_over_dn wal_dir_bytes)
log "  集群级 WAL 面（目录口径）：文件数=$WALF0 总字节=${WALB0}B；逐副本：$(wal_per_node)"
log "  逐副本 checkpoint 数：$(for h in "${DN[@]}"; do printf '%s=%s ' "${h##*.}" "$(wal_ckpt_cnt "$h")"; done)"
# 指标口径（源码印证 Metric.java:80-85；lib/wal_ext.sh ⑪）比扫目录权威 ⇒ 两个口径都打，互相交叉验证
log "  集群级 WAL 面（指标口径，file_count/file_size name=wal）：文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt) 字节=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
log "  指标口径逐副本：files=$(wal_metric_per_node wal_metric_file_cnt) bytes=$(wal_metric_per_node wal_metric_file_bytes)"
wal_metrics_dump "${DN[0]}"
[ "${WALF0:-0}" -ge 1 ] && pass "场景有效：WAL 目录存在 $WALF0 个 .wal 文件" \
  || fail "场景无效：WAL 文件数为 0（无法验证 WAL 路径；检查 dn_wal_dirs 与写路径）"

# 停机前 victim 自己的 WAL 面（证据；单副本为 0 只 WARN）
VF_BEFORE=$(wal_file_cnt "$VICTIM")
VB_BEFORE=$(wal_dir_bytes "$VICTIM")
[ "${VF_BEFORE:-0}" -ge 1 ] && pass "victim $VICTIM 停机前 WAL 文件数=$VF_BEFORE（字节=${VB_BEFORE}B）" \
  || warn "victim $VICTIM 停机前 WAL 文件数=0（可能已被 checkpoint 清理；仅记录，不判 FAIL）"
log "  $VICTIM WAL 清单样例：$(wal_ls "$VICTIM" | tr '\n' ' ' | cut -c1-300)"

# ---------------------------------------------------------------------------
# ③ 正常下线 victim（stop-datanode.sh，对比 W-04/W-05 的 kill -9 掉电）
# ---------------------------------------------------------------------------
log "--- ③ 正常下线 $VICTIM ---"
PROC_BEFORE=$(w06_proc_cnt "$VICTIM")
[ "${PROC_BEFORE:-0}" -ge 1 ] && pass "$VICTIM 下线前 DataNode 进程数=$PROC_BEFORE" \
  || fail "场景无效：$VICTIM 上找不到 DataNode 进程（无法做下线场景）"
wal_stop_dn "$VICTIM" || warn "  wal_stop_dn 返回非 0（继续按进程/状态复核）"
wait_dn_state "$VICTIM" notrunning "${DN_DOWN_WAIT_SEC:-180}" \
  || fail "场景无效：$VICTIM 未真正停止（show cluster 仍显示 Running）"
PROC_DOWN=$(w06_proc_cnt "$VICTIM")
[ "${PROC_DOWN:-0}" -eq 0 ] && pass "$VICTIM DataNode 进程已消失（正常 stop 生效）" \
  || fail "场景无效：$VICTIM 进程仍在（wal_dn_pid + kill -0 计数=$PROC_DOWN）"
# Leader 切换需要一点时间；给共识层留窗口，避免"刚停就写"被误当成产品问题
sleep 10

# ---------------------------------------------------------------------------
# ④ 下线期继续写入（RF=3 ⇒ 2/3 副本仍应接受写入）
# ---------------------------------------------------------------------------
log "--- ④ 下线期写入批2（RF=$DATA_RF；期望成功）---"
T0=$(date +%s)
w06_write_batch "$DB" "$BASE2" 2
T1=$(date +%s)
sleep 5
wait_scalar_tree "select count(s1) from $DB.d1;" "$(( ROWS * 2 ))" "$WIN" "下线期写入后 d1 行数" \
  || fail "下线期写入后 d1 行数不足（RF=$DATA_RF、仅 1 副本下线时写入应成功）"
TOT2=$(w06_total)
assert_eq "下线期写入后全库总行数（正常 stop 应可写）" "$TOT2" "$CNT2"
log "  下线期批2 写入耗时=$(( T1 - T0 ))s（耗时只作证据，不判 FAIL）"
FP_PRE=$(cmp_fp_tree "$DB")
log "  停机期指纹（基准，经 ${DN[0]}）：$FP_PRE"

# ---------------------------------------------------------------------------
# ⑤ 拉起 victim 并等它补齐
# ---------------------------------------------------------------------------
log "--- ⑤ 拉起 $VICTIM ---"
wal_start_dn "$VICTIM" || warn "  wal_start_dn 返回非 0（继续按状态复核）"
wait_dn_state "$VICTIM" running "${DN_RECOVER_WAIT_SEC:-300}" \
  || fail "场景无效：$VICTIM 未真正启动（show cluster 非 Running）"
PROC_UP=$(w06_proc_cnt "$VICTIM")
[ "${PROC_UP:-0}" -ge 1 ] && pass "$VICTIM DataNode 进程已恢复（计数=$PROC_UP）" \
  || fail "场景无效：$VICTIM 进程未起来"

# 恢复可见性：**轮询**，不假设即时可见（design_extract §4.4 未给恢复完成信号）
w06_wait_cnt_on "$VICTIM" "select count(s1) from $DB.d1;" "$(( ROWS * 2 ))" "$RESTART_WIN" \
  "恢复后经 $VICTIM 查询 d1 行数"

# 恢复后 WAL 面（证据）
VF_AFTER=$(wal_file_cnt "$VICTIM")
VB_AFTER=$(wal_dir_bytes "$VICTIM")
log "  WAL 面（$VICTIM，目录口径）：停机前 ${VF_BEFORE}f/${VB_BEFORE}B → 恢复后 ${VF_AFTER}f/${VB_AFTER}B"
log "  恢复后集群级 WAL 面（目录口径）：文件数=$(wal_sum_over_dn wal_file_cnt) 字节=$(wal_sum_over_dn wal_dir_bytes)B"
log "  恢复后逐副本 WAL：$(wal_per_node)"
log "  恢复后集群级 WAL 面（指标口径）：文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt) 字节=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
log "  $VICTIM 恢复后指标：nodes=$(wal_metric_node_num "$VICTIM") eff_ratio=$(wal_metric_eff_ratio "$VICTIM")"
# 注：**不要**用 WALNode 的"删除过期 WAL 条数"日志文案作判据（DEBUG 级、默认不落盘，见 lib/wal_ext.sh ⑪）
log "  $VICTIM WAL 日志尾部：$(wal_log_tail "$VICTIM" 6 | tr '\n' ' ' | cut -c1-300)"

# ---------------------------------------------------------------------------
# ⑥ 数据面判据（唯一 FAIL 来源）
# ---------------------------------------------------------------------------
log "--- ⑥ 数据面核对（唯一 FAIL 判据）---"
cmp_assert_same "下线/恢复前后全库 count/sum 指纹" "$FP_PRE" "$(cmp_fp_tree "$DB")"
assert_eq "恢复后全库总行数" "$(w06_total)" "$CNT2"
cmp_assert_nodes_same "恢复后逐副本 d1 全序列" \
  "$(cmp_fingerprint_on "${DN[0]}" tree "select s1 from $DB.d1 order by time")" \
  tree "select s1 from $DB.d1 order by time" "${DN[*]}"

# 该副本自己的 TsFile 是否补齐（证据；WAL 恢复后应直接刷盘，见 design_extract §4.3）
log "  逐副本 TsFile 数（$DB）：$(cmp_per_node cmp_all_sum "$DB")"

# ---------------------------------------------------------------------------
# ⑦ 收尾三件套（sync lag → 副本一致性 → 日志异常）
# ---------------------------------------------------------------------------
log "--- ⑦ 收尾三件套 ---"
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
# 说明：**不**安装 wal_install_err_pat 的 WAL 建议正则 —— 本用例会停/起节点，而该正则尚未在
# 本环境实跑标定（lib/wal_ext.sh 顶部即写明"默认不安装"）。WAL 日志只作证据（wal_log_tail /
# wal_positive_evidence）；按用例纪律，**唯一 FAIL 判据是数据面**。
# 若首跑后确认某条 WAL WARN 是已知无害的，再显式 opt-in：
#   wal_install_err_pat; export CMP_LOG_BENIGN_EXTRA='已知无害文案'
post_checks "select count(s1) from $DB.d1;" tree
cmp_case_finish "" tree ""
