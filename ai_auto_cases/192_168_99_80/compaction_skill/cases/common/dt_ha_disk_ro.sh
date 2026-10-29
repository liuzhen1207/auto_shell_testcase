#!/bin/bash
# ============================================================================
# DT-08 高可用：**合并期间把一个 DataNode 的数据盘挂成只读**（模拟磁盘 readonly 故障）
#
# 场景：单设备约 4MB × 2 个 TsFile（限流 1MB/s 把合并拖到十几秒）→ 开合并 → 在 VICTIM 上把
#       **数据目录挂成只读**（见下方"只读注入"说明：整盘 remount,ro 在本环境不可用）→ 观察 60s →
#       恢复可写 → 等恢复/追赶
# 判据：
#   ① **注入必须真的生效**（数据根下新建文件返回 `Read-only file system`），否则判 FAIL（场景无效）；
#   ② 只读期间：其它副本照常推进；数据不丢不坏（指纹/行数/载荷原文与起点一致）；
#   ③ 恢复可写后：数据目录确实可写（RW_OK）、该副本重新 Running、sync lag 归零、三副本数据一致、合并最终收敛；
#   ④ 日志里只有预期的"只读文件系统/IO 失败"错误，没有 NPE/OOM/越界/overlap 等异常（收尾 check_logs 也会扫）。
#
# ---------------------------------------------------------------------------
# 【RC8 V1→V2 口径修正（2026-10-17；报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.3 / §④ P1-3）】
#   V1 PASS 1023s f0 → V2 FAIL 1527s f1。唯一 FAIL 是收尾的"重启后三副本仍未收敛到**一致布局**"
#   （77:3/0/0/0 78:0/1/0/0 79:3/0/0/0），而功能面（指纹/行数/载荷/syncLag/自动恢复）全部 PASS。
#   根因：**合并是逐副本本地执行的**（不同副本各自选任务、各自产出），再加上 V2 follower 的文件落在
#   unsequence（DataRegion.java:4984/5009）⇒「同一时刻三副本布局串相同」这件事在 V2 下**结构性不成立**，
#   这不是"副本没追上"，也不是产品缺陷（RC6 那轮同样形态被记成 WARN 且 PASS）。
#   ⇒ 收敛判据改口径（**不是无条件放宽**）：
#     · 收敛 = 「判据集（V1=全部副本 / V2=leader）布局单一」**且**「每副本 TsFile 总数 ≤ 各自起点」；
#     · 布局串只作**证据**打印；非判据副本的差异只 WARN；
#     · FAIL 只留给**数据面不一致 / 追赶后 TsFile 反而增加**（这些硬判据一条都没动）。
# ---------------------------------------------------------------------------
# 安全：`trap` 保证无论用例怎么退出都会把数据目录挂回可写（remount,rw,bind + umount -l）。
# 用法： bash dt_ha_disk_ro.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_ha_disk_ro_${DATA_CONSENSUS}"

DB=root.dtro
ROWS=${DT_RO_ROWS:-6000}   # 6MB × 2 批/副本：限流 1MB/s 下合并要十几秒，保证只读注入落在**合并进行中**
PER=200
VICTIM="${DN[2]}"
RESTORED=0
ROOT="$DB_DIR/data"     # 真正被"挂成只读"的数据子树（TsFile/WAL/共识日志都在其下）

# 只读注入（实测结论，务必照抄）：
#   ① 整盘 `mount -o remount,ro /data` 在本环境**必然失败**：`mount: /data: mount point is busy.`
#      —— ext4 在**有进程持有可写 fd**（IoTDB 常驻打开 TsFile/WAL/日志）时不允许整盘转只读。
#   ② 因此用"**自绑定挂载 + remount,ro,bind**"把数据子树变成只读：新建/重命名/删除都返回
#      `Read-only file system`（合并要写**新**目标 TsFile、合并后要删源文件，正是被测路径），
#      已经打开的 fd 不受影响（这是该注入方式的已知边界，写进用例输出）。
#   ③ 注入后**必须硬校验**（在数据根下建文件必须 EROFS），校验不通过就判 FAIL（"场景无效"），
#      不允许"注入没生效却报 PASS"——首轮就是只 WARN 才出现假 PASS。
dt08_ro_on(){ local r1 r2 probe
  r1=$(sshx "$VICTIM" "mount -o remount,ro /data 2>&1 | head -1" 2>/dev/null | tr '\n' ' ')
  log "  ① 整盘 remount,ro /data → ${r1:-（无输出）}"
  r2=$(sshx "$VICTIM" "mount --bind $ROOT $ROOT 2>&1; mount -o remount,ro,bind $ROOT 2>&1; findmnt -T $ROOT -o OPTIONS -n" 2>/dev/null | tr '\n' ' ')
  log "  ② 数据子树只读（bind）→ ${r2:-（无输出）}"
  probe=$(sshx "$VICTIM" "touch $ROOT/.dt08_ro_probe 2>&1 | head -1" 2>/dev/null | tr '\n' ' ')
  log "  ③ 只读校验（在数据根下建文件）→ ${probe:-（无输出）}"
  printf '%s' "$probe" | grep -qiE 'read-only file system|EROFS' && echo 1 || echo 0; }

dt08_restore(){
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  log "--- 恢复 $VICTIM 的数据目录为可写（bind 先转 rw 再解绑，整盘 rw 兜底）---"
  sshx "$VICTIM" "mount -o remount,rw,bind $ROOT 2>/dev/null; umount -l $ROOT 2>/dev/null; mount -o remount,rw /data 2>/dev/null; rm -f $ROOT/.dt08_ro_probe; if touch $ROOT/.dt08_rw_probe 2>/dev/null; then rm -f $ROOT/.dt08_rw_probe; echo RW_OK; else echo RW_FAIL; fi; findmnt -T $ROOT -o TARGET,OPTIONS -n" 2>/dev/null | sed 's/^/    /' || true
}
# 优雅重启该 DN（TERM 停 → 起 → 等 Running）。只读故障后节点要重放/修复，起来比平时慢（实测 JVM ~110s）
dt08_dn_restart(){ local h=$1
  sshx "$h" "$DB_DIR/sbin/stop-datanode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  sleep 5
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_ro.log 2>&1 </dev/null &" || true
  sleep 10
  wait_dn_state "$h" running "${DT_RO_RECOVER_SEC:-420}"; }
# 收敛判据（改口径，2026-10-17）：判据集布局单一 **且** 每副本 TsFile 总数 ≤ 各自起点（详见文件头）
#   · 判据集 = V1 全部副本 / V2 region leader（lib/cmp.sh 的 judge set）
#   · 起点计数在造场景时抓成 TS0_NODE 串（"77=2 78=2 79=2 "），逐副本比较，避免"某台涨了被加起来稀释"
DT08_TS0_NODE=""
dt08_snap_ts0(){ local db=$1 h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}=$(cmp_all_cnt_node "$h" "$db") "; done
  DT08_TS0_NODE="$out"; }
dt08_node_ts0(){ printf '%s\n' "$DT08_TS0_NODE" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
dt08_no_growth(){ local db=$1 h cur base bad=0
  for h in "${DN[@]}"; do
    cur=$(cmp_all_cnt_node "$h" "$db"); base=$(dt08_node_ts0 "${h##*.}"); base=${base:-0}
    [ "${cur:-0}" -le "$base" ] || bad=$(( bad + 1 ))
  done; [ "$bad" -eq 0 ] && echo 1 || echo 0; }
# 收敛判据的**判定**（超时后调用）：某副本 TsFile 总数 > 起点 ⇒ FAIL（合并没推进/文件反而变多）；
#   否则只 WARN（"布局串不同"是逐副本独立合并 + V2 follower 落 unseq 的必然结果，不是缺陷）
dt08_probe_growth(){ local db=$1 h cur base bad=0 det=""
  for h in "${DN[@]}"; do
    cur=$(cmp_all_cnt_node "$h" "$db"); base=$(dt08_node_ts0 "${h##*.}"); base=${base:-0}
    [ "${cur:-0}" -le "$base" ] || { bad=$(( bad + 1 )); det="$det ${h##*.}:$base→$cur"; }
  done
  if [ "$bad" -eq 0 ]; then
    warn "  重启后判据集布局仍未收敛，但**每副本 TsFile 总数都 ≤ 起点**（起点 ${DT08_TS0_NODE}→现在 布局 $(cmp_lay "$db")）⇒ 只记 WARN（逐副本独立合并 + V2 follower 文件落 unsequence，属设计差异；数据面判据见下）"
  else
    fail "  追赶后有副本的 TsFile 总数比起点还多（$det）⇒ 合并没有推进/文件反而增加（布局 $(cmp_lay "$db")）"
  fi; }
# 等"收敛"：判据集布局单一 **且** 每副本 TsFile 总数不增加（1=收敛 0=超时）
dt08_wait_uni(){ local db=$1 t=$2 dl
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    cmp_lay_probe "$db"
    if [ "$(printf '%s' "$CMPJ_JUDGE_UNI" | wc -w)" = 1 ] && [ "$(dt08_no_growth "$db")" = 1 ]; then echo 1; return 0; fi
    sleep 10
  done; echo 0; }
trap dt08_restore EXIT
trap 'dt08_restore; exit 130' INT TERM

PAYLOAD=$(printf 'q%.0s' $(seq 1 1000))
dt08_write(){ local base=$1 b=$2 ts i=0 vals="" stmts=""   # i 必须显式初始化：`set -u` 下 `$(( i + 1 ))` 会对未赋值变量报 unbound（本轮踩到）
  for ((ts=1; ts<=ROWS; ts++)); do
    vals="$vals($(( base + (b-1)*100000 + ts*10 )),'$PAYLOAD'),"
    i=$(( i + 1 ))
    if [ $(( i % PER )) -eq 0 ]; then stmts="${stmts}insert into $DB.d1(time,s1) values ${vals%,};
"; vals=""; fi
  done
  if [ -n "$vals" ]; then stmts="${stmts}insert into $DB.d1(time,s1) values ${vals%,};
"; fi
  printf '%s' "$stmts" | session_tree >/dev/null
  sq "flush;" >/dev/null; }

log "--- 集群准备：三类合并先关；限流 1MB/s（让合并持续足够久，便于插入只读故障）---"
EXTRA_CONF="$CMP_EXTRA_WRITE,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare
log "  /data 挂载（$VICTIM）：$(sshx "$VICTIM" "findmnt -T $DB_DIR -o TARGET,SOURCE,FSTYPE,OPTIONS -n" 2>/dev/null | head -1)"
log "  只读前健康：Running 节点数=$(sq 'show cluster;' 2>/dev/null | grep -c Running)"

log "--- 1) 造场景（约 4MB × 2 个 TsFile）+ 起点指纹 ---"
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=TEXT, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
BASE=$(now_ms)
dt08_write "$BASE" 1
dt08_write "$BASE" 2
cmp_wait_close "$DB" 2 120 >/dev/null || warn "  close 事件未达 2"
cmp_wait_lay "$DB" "2/0/0/0" 150 >/dev/null || warn "  起点布局=$(cmp_lay "$DB")（期望 2/0/0/0）"
FP0=$(cmp_fp_tree "$DB"); BYTES=$(cmp_bytes_sum "$DB"); TS0=$(cmp_all_sum "$DB")
CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
# TEXT 序列的 `sum` 不参与（无聚合语义）⇒ 数据完整性用"行数 + 首行 1KB 载荷原文"直接比对
ROW0=$(cmp_rows_series "$DB.d1.s1"); VAL0=$(cmp_vals_series "$DB.d1.s1" 1)
log "  起点：布局=$(cmp_lay "$DB") TsFile=$TS0 字节=$BYTES 行数=$CNT0（单序列可见 $ROW0 行，首值长度 $(printf '%s' "$VAL0" | tr -d '|' | wc -c)）"
dt08_snap_ts0 "$DB"
log "  起点逐副本 TsFile 总数（收敛判据的基线）：${DT08_TS0_NODE}"
[ "${TS0:-0}" -ge 2 ] && pass "  只读注入前确有 ≥2 个 TsFile（$TS0）" || fail "  起点 TsFile 只有 ${TS0:-0} 个（场景无效）"

log "--- 2) 开合并（限流）→ 3s 后把 $VICTIM 的数据目录挂成只读 ---"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 3
RO_ON=$(dt08_ro_on | tail -1)   # 函数里 log 的明细已写进 $OUT；这里只取最后一行判定值
[ "$RO_ON" = 1 ] && pass "  只读注入成功：$VICTIM:$ROOT 下新建文件被拒（Read-only file system）" \
  || fail "  只读注入未生效（整盘 remount 被 EBUSY 拒 + bind 只读校验失败）⇒ 场景无效，不得判 PASS"

log "--- 3) 只读窗口内观察 60s ---"
sleep 60
LAY_RO=$(cmp_lay "$DB"); FIN_RO=$(cmp_inner_finish "$DB")
ST_RO=$(dn_state "$VICTIM")
log "  只读窗口：布局=$LAY_RO finishes=$FIN_RO $VICTIM 状态=<$ST_RO>"
cmp_assert_same "  只读窗口内数据指纹（基准=起点）" "$FP0" "$(cmp_fp_tree "$DB")"
cmp_assert_same "  只读窗口内序列行数" "$ROW0" "$(cmp_rows_series "$DB.d1.s1")"
cmp_assert_same "  只读窗口内首行 1KB 载荷原文" "$VAL0" "$(cmp_vals_series "$DB.d1.s1" 1)"
# 实测：磁盘只读时产品会把该节点的系统模式切成 ReadOnly（日志 `Set system mode from Running to ReadOnly`、
# `Only query statements are permitted`），集群视图里状态就是 `ReadOnly` —— 这是"故障被正确识别"的正面证据。
if [ "$ST_RO" = "ReadOnly" ]; then
  pass "  只读期间产品把该节点标记为 ReadOnly（检测到磁盘只读、只允许查询）"
elif [ -n "$ST_RO" ]; then
  pass "  只读期间集群仍能看到该 DataNode（状态 $ST_RO）"
else
  warn "  只读期间 $VICTIM 不在集群视图里（记录）"
fi
# 只读期间**该副本自己**的合并必须做不下去（文件数不下降），否则说明注入没有真正拦住写
LAY_VICTIM=$(cmp_lay "$DB" | tr ' ' '\n' | grep -E "^${VICTIM##*.}:" | cut -d: -f2)
log "  只读期间 $VICTIM 自身布局=$LAY_VICTIM（合并要在该盘写新目标文件 ⇒ 应保持未合并）"

log "--- 4) 恢复可写并等追赶 ---"
RW=$(dt08_restore 2>&1 | grep -oE 'RW_(OK|FAIL)' | head -1)
[ "$RW" = RW_OK ] && pass "  数据目录已恢复可写（RW_OK）" \
  || fail "  数据目录未恢复可写（$RW）—— 该 DataNode 会一直写不进去，必须人工处理"
sleep 15
ST_AFTER=$(dn_state "$VICTIM")
ALIVE=$(sshx "$VICTIM" "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null | tr -d '\r ')
log "  恢复可写后：$VICTIM 状态=<$ST_AFTER> 进程=$([ -n "$ALIVE" ] && echo 在 || echo 无)"
if [ "$ST_AFTER" = "Running" ] && [ -n "$ALIVE" ]; then
  pass "  $VICTIM 已自动恢复 Running（无需重启）"
else
  # 实测：ReadOnly 模式不会因为磁盘恢复可写而自动回到 Running，必须重启进程
  log "  -> $VICTIM 未回到 Running（状态 <$ST_AFTER>），按 TERM 停 + 起 恢复"
  dt08_dn_restart "$VICTIM" && pass "  $VICTIM 重启后恢复 Running" \
    || fail "  $VICTIM 重启后仍非 Running（等待 ${DT_RO_RECOVER_SEC:-420}s）"
fi
check_sync_lag || fail "  只读恢复后 sync lag 未归零"
cmp_set_hot enable_seq_space_compaction true >/dev/null
# 追赶判据（比"TsFile 总数下降"更强）：落后的副本必须和其它副本**收敛到同一布局**。
# 分两段等 —— ① 先给 180s 看能否**自动**重试（把该行为记下来）；② 不收敛就重启该 DN 触发 region 恢复后再等 240s。
# 实测：只读期间失败的内合并会留下 target/`*.inner-compaction.log`，**该 region 在重启/重开之前不会重试**
#       （21:29:50 失败 → 到 21:38 都没有新任务；重启触发 `[Compaction][Recover] … Recover compaction successfully`
#       之后 12s 内就把 2 个文件并成了 1 个）。
if [ "$(dt08_wait_uni "$DB" 180)" = 1 ]; then
  cmp_lay_probe "$DB"
  pass "  恢复可写后**自动**追赶完成（无需重启）：判据集 ${CMPJ_JUDGE_SPEC% } 布局单一且各副本 TsFile 总数 ≤ 起点（$(cmp_lay "$DB")）"
  cmp_warn_followers "DT-08 追赶（自动）" "$(printf '%s' "$CMPJ_JUDGE_UNI" | tr -d ' ')"
else
  warn "  180s 内未自动收敛（布局=$(cmp_lay "$DB")）⇒ 该 region 有未恢复的合并产物，需重启节点才重试"
  dt08_dn_restart "$VICTIM" && pass "  $VICTIM 重启后恢复 Running" || fail "  $VICTIM 重启后仍非 Running"
  cmp_set_hot enable_seq_space_compaction true >/dev/null
  if [ "$(dt08_wait_uni "$DB" 240)" = 1 ]; then
    cmp_lay_probe "$DB"
    pass "  重启触发 region 恢复后追赶完成：判据集 ${CMPJ_JUDGE_SPEC% } 布局单一且各副本 TsFile 总数 ≤ 起点（$(cmp_lay "$DB")）"
    cmp_warn_followers "DT-08 追赶（重启后）" "$(printf '%s' "$CMPJ_JUDGE_UNI" | tr -d ' ')"
  else
    # 【口径修正】不再用"三副本布局串相同"判 FAIL（逐副本独立合并 + V2 follower 文件落 unseq ⇒ 结构性不成立）；
    #   FAIL 只留给"追赶后某副本 TsFile 总数反而比起点多"（= 合并没有推进/文件变多）。
    dt08_probe_growth
  fi
fi
log "  追赶后：布局=$(cmp_lay "$DB") TsFile=$TS0→$(cmp_all_sum "$DB") finishes=$FIN_RO→$(cmp_inner_finish "$DB")"
cmp_assert_same "  故障恢复后数据指纹（与起点一致）" "$FP0" "$(cmp_fp_tree "$DB")"
cmp_assert_same "  故障恢复后序列行数" "$ROW0" "$(cmp_rows_series "$DB.d1.s1")"
cmp_assert_same "  故障恢复后首行 1KB 载荷原文" "$VAL0" "$(cmp_vals_series "$DB.d1.s1" 1)"
assert_eq "  恢复后行数" "$(row_sum "$(sq "select count(s1) from $DB.**;")")" "$CNT0"
TMP=$(cmp_tmp_leftover "$DB")
[ "${TMP:-0}" -eq 0 ] && pass "  只读故障恢复后没有残留临时/目标文件" \
  || warn "  有 $TMP 个残留临时/目标文件（记录：只读期间失败的合并可能留下 target）"

log "--- 5) 只读期间不得出现非预期异常 ---"
NERR=0
for h in "${DN[@]}"; do
  n=$(sshx "$h" "grep -haE 'NullPointerException|OutOfMemoryError|IndexOutOfBoundsException|ArrayIndexOutOfBoundsException|has overlapped data|CompactionTableSchemaNotMatchException|DataTypeInconsistentException' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  NERR=$(( NERR + ${n:-0} ))
done
[ "$NERR" -eq 0 ] && pass "  只读故障期间没有出现 NPE/OOM/越界/overlap 等异常" || fail "  出现 $NERR 条非预期异常（见收尾日志扫描）"

log "--- 收尾三件套（只读恢复后再做；把只读/IO 预期的错误列入 benign）---"
# 只读注入**本身**会产生的 ERROR 都属于预期（这些正是被测路径）：
#   `[Compaction] INNER_SEQ task meets error` / `CompactionRecoverException: failed to delete target file`
#   `Set system mode from Running to ReadOnly` / `Only query statements are permitted`
export CMP_LOG_BENIGN_EXTRA='Read-only file system|EROFS|read-only|ReadOnly|Only query statements are permitted|system mode from Running to ReadOnly|INNER_SEQ task meets error|CompactionRecoverException|Failed to recover compaction|failed to (delete|create|write|rename|open)[^|]*(target file|No such file|Permission denied|read-only)|No space left on device'
post_checks "select s1 from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
