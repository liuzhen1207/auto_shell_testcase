#!/bin/bash
# ============================================================================
# W-07 元数据变更后的 WAL 恢复（树模型；库名 root.walmeta）
# ----------------------------------------------------------------------------
# 目标（cases/cases.tsv W-07）：建库/建序列 → 写数据 → `DELETE TIMESERIES` / `DROP DATABASE` /
#   `DELETE ... WHERE time<=T` 等**元数据与数据变更（一律不 flush）** → kill -9 **全部** DataNode
#   （掉电语义）→ 重启 → 校验 schema（SHOW TIMESERIES / COUNT TIMESERIES）与数据是否如实反映
#   已执行的 DDL/DML；WAL 面记录恢复前后的文件数/字节与指标（**证据，不是判据**）。
#
# 需求依据（docs/req_sources/design_extract.md）：
#   · §4.3「WAL 重启恢复」：恢复粒度 = WAL Node，流程 = 读 checkpoint 恢复未刷盘 MemTable →
#     读 WAL Entry 分给 0 层未封口 TsFile 的 UnsealedTsFileRecoverPerformer 写入 →
#     删除该 WALNode 下的所有文件。**该节只描述"数据侧"**。
#   · §3.1 WAL Entry 的 Type 只有三类写入计划：0x04 InsertRowNode / 0x05 InsertTabletNode /
#     0x06 DeleteDataNode（+0x03 MemTable 快照）⇒ `DELETE FROM … WHERE time<=T` 是有 WAL Entry 的，
#     而 **DDL（建库/建序列/DROP）不在 WALNode 的 WAL Entry 类型里**。
#   · ⇒ **元数据 WAL 的恢复边界文档未写**：库级 DDL 走 ConfigNode 的 schema partition、
#     时序级 DDL 走 DataNode 上的 SchemaRegion（二者是 Ratis 一致性，日志在 `data/datanode/consensus` 下），
#     与 `dn_wal_dirs`（WALNode 的 WAL 目录）不是一回事。本用例**不对"元数据由谁保证持久"下结论**
#     （如实 WARN + 打印两侧证据），只判定"掉电重启后 schema 与数据是否如实反映已执行的 DDL/DML"。
#   · §4.4：文档**没有**给"恢复完成"的任何信号 ⇒ 一律轮询数据/元数据可见，不假设即时可见。
#
# 判据（FAIL 只来自数据面 / 元数据面的一致性）：
#   1) 场景有效性（硬）：写入行数达标、元数据变更在 kill -9 前**确实生效**、
#      全部 DN 真的被 kill -9 且真的重新 Running；集群级 WAL 文件数 > 0；
#   2) 掉电重启后：未被删的序列数据一条不少（d1 行数）、`DELETE FROM` 的删除边界仍生效（d4 行数）、
#      被 `DELETE TIMESERIES` 的设备不得再出现在 `SHOW TIMESERIES`、被 DROP 的库不得再出现；
#   3) 全库 count/sum 指纹与掉电前完全一致；
#   4) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无 NPE·OOM·越界等异常；
#   5) 元数据 WAL 恢复边界、WAL 文件数/字节、恢复耗时 ⇒ WARN / 证据（文档未写，不判 FAIL）。
#
# 用法： bash cases/common/wal_recovery_metadata.sh [--consensus IoTConsensus|IoTConsensusV2]
#
#   ⚠ **本条未实跑**（写就时 99.80 正在跑合并长回归，禁止任何集群动作；本用例会 kill -9 并重启
#     全部 DataNode，属"任何集群动作"）。仅保证 `bash -n` 与 tools/selftest.sh 静态检查通过。
#
# watch list（首跑前逐条确认，3~5 条）：
#   ① `DELETE TIMESERIES <dev>.**` 语法：树模型**必须带 `.**`**（不带会去删一个不存在的路径、
#      0 行被删而且不报错）⇒ 先用 `SHOW TIMESERIES` 行数确认真降下来了，再往下走。
#   ② `DELETE FROM <dev>.** WHERE time<=T` 走共识：必须轮询等副本应用（本用例已用 wait_scalar_tree），
#      否则"删除边界"的基线会偏大，掉电后反而"看起来一致"。
#   ③ kill -9 掉全部 DN 后，CLI（连 QDN=DN[0]）**连不上**，`show cluster`/dn_state 全部不可用
#      ⇒ 下线判定只能靠 `wal_dn_pid`（/proc/*/cmdline，只认 java + DataNode；**不要**用 pgrep，
#        它会把远端 `bash -c` 包装 shell 数进去）；本用例已如此实现。同理**不要**用 wal_start_dn 逐个拉起
#      （它内部靠 show cluster 判 Running，全下线时每个都会白等 DN_RECOVER_WAIT_SEC）。
#   ④ `COUNT TIMESERIES` 若在本版本不可用（输出含 Exception）⇒ 只以 `SHOW TIMESERIES` 行数为判据，
#      COUNT 记 WARN（不判 FAIL），避免把语法差异当成产品问题。
#   ⑤ 掉电重启后 WAL 文件数可能直接变 0（§4.3：恢复成功后删除该 WALNode 下所有文件）
#      ⇒ 只记录方向，不假设"必须下降"。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_recovery_metadata_${DATA_CONSENSUS}"

DB=root.walmeta
DBX=root.walmeta_drop          # 抛掉（DROP DATABASE）的那个库
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
DEL_DEVS=2                     # DELETE TIMESERIES 删掉的设备数（d5、d6）
DEL_ROWS=150                   # DELETE FROM d4 WHERE time<=T 删掉的行数
WIN=${WAL_REPLAY_WIN_SEC:-300}
TS_EXPECT=$(( DEVS - DEL_DEVS ))
KEEP_D4=$(( ROWS - DEL_ROWS ))
KEEP_TOTAL=$(( (DEVS - DEL_DEVS) * ROWS - DEL_ROWS ))

# 时间戳基准固定（可复现；不用随机/当前时间，便于对照相同基准的指纹）
BASE=$(( ($(date +%s) - 7200) * 1000 ))
# 【RC8 第二轮修正（2026-10-20）】原来的 `BASE + DEL_ROWS*10 + 5` 会**多删一行**：
#   行时间戳是 `BASE + k*10`(k=0..ROWS-1)，`time <= BASE+150*10+5 = BASE+1505` 命中的是 k=0..150 共 **151** 行，
#   于是 d4 只剩 149（期望 150）、全库 1049（期望 1050），4 条判据假 FAIL。
#   正确边界：只删前 DEL_ROWS 个点 ⇒ 最大命中 ts = BASE + (DEL_ROWS-1)*10，留 +5 的余量。
DEL_T=$(( BASE + (DEL_ROWS - 1) * 10 + 5 ))

# ---------------------------------------------------------------------------
# 本地辅助
# ---------------------------------------------------------------------------
# DataNode 进程数（"是否真的下线"的唯一判据）
#   pid 由 lib/wal_ext.sh 的 `wal_dn_pid` 精确识别（/proc/*/cmdline，只认 java + DataNode），
#   再用 `kill -0` 复核；**不要**用 `pgrep -c -f com.timecho.iotdb.DataNode`——它会把远端
#   `bash -c` 包装 shell 一起数进去 ⇒ DN 全部 kill -9 之后计数仍 ≥1 ⇒ "没真正下线"的假 FAIL。
w07_proc_cnt(){ local p
  p=$(wal_dn_pid "$1"); [ -n "$p" ] || { echo 0; return 0; }
  wal_dn_alive "$1" "$p" && echo 1 || echo 0; }

# 写一批数据（**不 flush**：这批数据的持久性必须由 WAL 保证）
w07_write_batch(){ local db=$1 devs=$2 d k ts vals
  for ((d=1; d<=devs; d++)); do
    vals=""
    for ((k=0; k<ROWS; k++)); do
      ts=$(( BASE + k * 10 ))
      vals="$vals($ts,$(( k + 1 ))),"
      if [ $(( (k + 1) % 500 )) -eq 0 ]; then
        sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
          || warn "  [$db] 设备$d 第 $((k+1)) 点写入返回非空（行数断言会兜底）"
        vals=""
      fi
    done
    [ -n "$vals" ] && { sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
      || warn "  [$db] 设备$d 尾批写入返回非空"; }
  done
  log "  [$db] 写入完成（每设备 $ROWS 点，**未 flush**）"
}

w07_total(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w07_ts_cnt(){ n_rows "$(sq "show timeseries $DB.**;")"; }

# 轮询 SHOW TIMESERIES 行数（元数据可见性；DDL 走共识，不假设即时生效）
w07_wait_ts_cnt(){ local want=$1 win=$2 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(w07_ts_cnt)
    got=${got:-0}
    if [ "$got" = "$want" ]; then pass "SHOW TIMESERIES 行数=$got（期望 $want）"; return 0; fi
    sleep 3
  done
  fail "SHOW TIMESERIES 行数=[$got] 期望=[$want]（等 ${win}s 未达到）"
  return 1; }

# 轮询某库从 SHOW DATABASES 消失（DROP DATABASE 可见性）
w07_wait_db_gone(){ local win=$1 dl out
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    out=$(sq 'show databases;' 2>&1)
    if ! printf '%s' "$out" | grep -qF "$DBX"; then pass "库 $DBX 已不在 SHOW DATABASES 结果里"; return 0; fi
    sleep 3
  done
  fail "库 $DBX 仍在 SHOW DATABASES 结果里（DROP DATABASE 未生效，等 ${win}s）"
  return 1; }

# 元数据侧的"另一本账"：SchemaRegion/ConfigNode 的一致性日志在 consensus 目录（证据）
w07_consensus_evidence(){ local h
  for h in "${DN[@]}"; do
    log "  [$h] consensus 目录（schema/data region 的 Ratis 日志，非 WALNode 的 wal_dirs）：$(sshx "$h" "find $DB_DIR/data/datanode/consensus -maxdepth 1 -type d 2>/dev/null | tail -4" | tr '\n' ' ')"
  done; }

log "=== W-07 目标：元数据/数据变更（不 flush）后 kill -9 全部 DN，再重启核对 schema 与数据 ==="
log "  库=$DB（含 $DEVS 设备）抛掉库=$DBX 期望：timeseries=$TS_EXPECT d4 保留=$KEEP_D4 全库总行数=$KEEP_TOTAL"
log "  consensus=${CONSENSUS_CLASS##*.} DATA_RF=$DATA_RF 删除时间界=$DEL_T"

# ---------------------------------------------------------------------------
# ① 集群准备
# ---------------------------------------------------------------------------
log "--- ① 集群准备 ---"
EXTRA_CONF="$WAL_EXTRA_DEFAULT" cmp_cluster_prepare
log "  生效值抽检（${DN[0]}）：wal_mode=$(wal_eff "${DN[0]}" wal_mode) buffer=$(wal_eff "${DN[0]}" wal_buffer_size_in_byte)"
w07_consensus_evidence

# ---------------------------------------------------------------------------
# ② 建库/建序列 + 写数据（不 flush）
# ---------------------------------------------------------------------------
log "--- ② 建库建序列 + 写数据（未 flush）---"
cmp_make_tree_db "$DB" "$DEVS"
sq "create database $DBX;" >/dev/null
cmp_make_tree_db "$DBX" 2
w07_write_batch "$DB" "$DEVS"
w07_write_batch "$DBX" 2
wait_scalar_tree "select count(s1) from $DB.d1;" "$ROWS" 90 "写入后 d1 行数"
assert_eq "写入后 $DB 全库总行数" "$(w07_total)" "$(( DEVS * ROWS ))"
w07_wait_ts_cnt "$DEVS" 90

# 场景有效性：WAL 目录必须真的有 .wal 文件
WALF0=$(wal_sum_over_dn wal_file_cnt)
log "  集群级 WAL 面（目录口径）：文件数=$WALF0 字节=$(wal_sum_over_dn wal_dir_bytes)B；逐副本：$(wal_per_node)"
log "  集群级 WAL 面（指标口径）：文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt) 字节=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
wal_metrics_dump "${DN[0]}"
[ "${WALF0:-0}" -ge 1 ] && pass "场景有效：WAL 目录存在 $WALF0 个 .wal 文件" \
  || fail "场景无效：WAL 文件数为 0（无法验证 WAL 恢复路径）"

# ---------------------------------------------------------------------------
# ③ 元数据 + 数据变更（一律不 flush）
# ---------------------------------------------------------------------------
log "--- ③ 元数据变更：DELETE TIMESERIES / DELETE FROM(d4) / DROP DATABASE（未 flush）---"
sq "delete timeseries $DB.d5.**;" >/dev/null
sq "delete timeseries $DB.d6.**;" >/dev/null
sq "delete from $DB.d4.** where time <= $DEL_T;" >/dev/null
sq "drop database $DBX;" >/dev/null
# DDL/DML 都走共识 ⇒ 轮询等生效（AGENTS/前序 skill 的教训：不等就会把"未应用"当成"恢复丢失"）
w07_wait_ts_cnt "$TS_EXPECT" 120
wait_scalar_tree "select count(s1) from $DB.d4;" "$KEEP_D4" 120 "DELETE FROM 生效后 d4 行数"
w07_wait_db_gone 120
assert_eq "变更后 $DB 全库总行数" "$(w07_total)" "$KEEP_TOTAL"

# 变更生效后的指纹（掉电恢复后必须与它完全一致）
FP_PRE=$(cmp_fp_tree "$DB")
log "  掉电前指纹（基准）：$FP_PRE"
TS_ROWS=$(sq "show timeseries $DB.**;")
assert_not_contains "被 DELETE TIMESERIES 的 d5 不应再出现" "$TS_ROWS" "\.d5\."
assert_not_contains "被 DELETE TIMESERIES 的 d6 不应再出现" "$TS_ROWS" "\.d6\."
# COUNT TIMESERIES 只作交叉校验：语法/接口不可用时记 WARN，不判 FAIL（文档未给该 SQL，见 watch ④）
CTS=$(sq "count timeseries $DB.**;")
if printf '%s' "$CTS" | grep -qiE 'Exception'; then
  warn "COUNT TIMESERIES 在本版本不可用（输出含 Exception）⇒ 只以 SHOW TIMESERIES 行数为判据：$(printf '%s' "$CTS" | tr '\n' ' ' | cut -c1-160)"
else
  assert_eq "COUNT TIMESERIES 与 SHOW TIMESERIES 行数一致" "$(scalar "$CTS")" "$TS_EXPECT"
fi

# ---------------------------------------------------------------------------
# ④ kill -9 全部 DataNode（掉电语义；不给 JVM 任何收尾机会）
# ---------------------------------------------------------------------------
log "--- ④ kill -9 全部 ${#DN[@]} 个 DataNode ---"
for h in "${DN[@]}"; do
  wal_kill9_dn "$h" || warn "  kill -9 $h 返回非 0（按进程数复核）"
done
sleep 5
# 注：此刻所有 DN 都下线，CLI 连 QDN 会失败 ⇒ **只能**靠 `wal_dn_pid`（/proc/*/cmdline，
#     只认 java + DataNode）+ `kill -0` 判"是否真的下线"（不要用 pgrep：会把远端包装 shell 数进去）
DOWN_OK=0
for h in "${DN[@]}"; do
  n=$(w07_proc_cnt "$h")
  if [ "${n:-0}" -eq 0 ]; then DOWN_OK=$(( DOWN_OK + 1 )); else warn "  $h 仍有 $n 个 DataNode 进程"; fi
done
[ "$DOWN_OK" -eq "${#DN[@]}" ] && pass "全部 ${#DN[@]} 个 DN 已因 kill -9 下线（掉电语义成立）" \
  || fail "场景无效：只有 $DOWN_OK/${#DN[@]} 个 DN 真正下线"

# ---------------------------------------------------------------------------
# ⑤ 重启全部 DataNode（先全拉起，再等集群就绪）
# ---------------------------------------------------------------------------
log "--- ⑤ 重启全部 DataNode ---"
log "  说明：不用逐个 wal_start_dn —— 它内部用 show cluster 判 Running，DN 全下线时 CLI 连不上，"
log "        串行调用会把 DN_RECOVER_WAIT_SEC 白等一遍；改为‘先全部拉起 + wait_cluster_ready’。"
for h in "${DN[@]}"; do
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_w07.log 2>&1 &" \
    || warn "  启动 $h 返回非 0"
done
wait_cluster_ready || fail "集群未在 ${CLUSTER_READY_TIMEOUT}s 内回到就绪（期望 $((${#CN[@]} + ${#DN[@]})) 个 Running）"
UP_OK=0
for h in "${DN[@]}"; do
  if wait_dn_state "$h" running "${DN_RECOVER_WAIT_SEC:-300}"; then UP_OK=$(( UP_OK + 1 )); else warn "  $h 未恢复 Running"; fi
done
[ "$UP_OK" -eq "${#DN[@]}" ] && pass "全部 ${#DN[@]} 个 DN 已恢复 Running" \
  || fail "场景无效：只有 $UP_OK/${#DN[@]} 个 DN 恢复 Running"

# WAL 面：恢复前后的文件数/字节（§4.3 最后一步会删除该 WALNode 下所有文件 ⇒ 方向不定，只记录）
WALF1=$(wal_sum_over_dn wal_file_cnt)
log "  重启后 WAL 面（目录口径）：文件数=$WALF0 → $WALF1；逐副本=$(wal_per_node)"
log "  重启后 WAL 面（指标口径）：文件数=$(wal_metric_sum_over_dn wal_metric_file_cnt) 字节=$(wal_metric_sum_over_dn wal_metric_file_bytes)"
for h in "${DN[@]}"; do wal_metrics_dump "$h"; done
if [ "${WALF1:-0}" -gt 0 ]; then
  wal_wait_replay "$DB" 120     # 弱观测：WAL 被消费（文件数下降）；不作为判据
else
  log "  重启后 WAL 文件数已为 0（与 §4.3‘恢复成功后删除该 WALNode 下所有文件’一致）"
fi
for h in "${DN[@]}"; do
  log "  [$h] WAL 相关日志尾部：$(wal_log_tail "$h" 5 | tr '\n' ' ' | cut -c1-240)"
done

# ---------------------------------------------------------------------------
# ⑥ 恢复后判定（轮询可见性 → 数据/元数据面硬判据）
# ---------------------------------------------------------------------------
log "--- ⑥ 恢复后：数据面 + 元数据面判定 ---"
wait_scalar_tree "select count(s1) from $DB.d1;" "$ROWS" "$WIN" "恢复后 d1 行数（未被删的序列一条不少）"
wait_scalar_tree "select count(s1) from $DB.d4;" "$KEEP_D4" "$WIN" "恢复后 d4 行数（DELETE FROM 边界仍生效）"
w07_wait_ts_cnt "$TS_EXPECT" "$WIN"
w07_wait_db_gone "$WIN"

TS_ROWS2=$(sq "show timeseries $DB.**;")
assert_not_contains "恢复后被 DELETE TIMESERIES 的 d5 仍不应出现" "$TS_ROWS2" "\.d5\."
assert_not_contains "恢复后被 DELETE TIMESERIES 的 d6 仍不应出现" "$TS_ROWS2" "\.d6\."
cmp_assert_same "掉电/恢复前后全库 count/sum 指纹" "$FP_PRE" "$(cmp_fp_tree "$DB")"
assert_eq "恢复后全库总行数" "$(w07_total)" "$KEEP_TOTAL"
CTS2=$(sq "count timeseries $DB.**;")
if printf '%s' "$CTS2" | grep -qiE 'Exception'; then
  warn "恢复后 COUNT TIMESERIES 仍不可用（只看 SHOW TIMESERIES 行数）：$(printf '%s' "$CTS2" | tr '\n' ' ' | cut -c1-160)"
else
  assert_eq "恢复后 COUNT TIMESERIES" "$(scalar "$CTS2")" "$TS_EXPECT"
fi

# 不可判定项：如实 WARN（文档未写元数据 WAL 的恢复边界）
warn "元数据 WAL 恢复边界不可判定（文档未写）：design_extract §4.3 只描述数据侧 WALNode 恢复，§3.1 的 WAL Entry Type 里也没有 DDL ⇒ 库级 DDL 走 ConfigNode schema partition、时序级 DDL 走 DN 的 SchemaRegion（Ratis，日志在 data/datanode/consensus），与 dn_wal_dirs 不是同一本账。本用例只证明‘掉电重启后 schema/数据如实反映已执行的 DDL/DML’，不对‘元数据由谁保证持久’下结论。"

# ---------------------------------------------------------------------------
# ⑦ 收尾三件套
# ---------------------------------------------------------------------------
log "--- ⑦ 收尾三件套 ---"
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
# 说明：**不**安装 wal_install_err_pat 的 WAL 建议正则（本用例会 kill -9 全部 DN，该正则尚未实跑标定；
# lib/wal_ext.sh ⑪ 也写明"不要拿 DEBUG 文案当判据"）。WAL 日志只作证据 ⇒ 唯一 FAIL 判据是数据面。
post_checks "select count(s1) from $DB.d1;" tree
cmp_case_finish "" tree ""
