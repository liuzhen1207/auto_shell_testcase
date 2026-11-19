#!/bin/bash
# ============================================================================
# CO-33 未排序 TsFile 的**真实修复链路**（load 导入路径 + START REPAIR DATA）
#
# 为什么需要专门构造：用 SQL 正常写入时，TsFile 一定是有序的，也拿不到
# `NEED_TO_REPAIR_*` 状态（CO-32 只能做"不误报"的负向检查）。要真正走一遍修复链路，
# 必须造一个**内部时间乱序**的 TsFile 再 `load` 进来。
#
# 构造方式完全对齐 IoTDB 官方集成测试 `IoTDBRepairDataIT.generateUnsortedFile()`
# （integration-test .../iotdb/db/it/IoTDBRepairDataIT.java，rc/2.0.12.1）：
#   用底层 `TsFileIOWriter` + `ChunkWriterImpl` 按 2,3,5,4 的顺序写点 → 文件内部乱序
#   → `load '<dir>'` → 断言 SELECT 结果**不是**升序（场景有效性）
#   → `START REPAIR DATA` → 轮询直到 SELECT 恢复升序。
# 本用例相比官方测试的加强：每个点的值互不相同（11/12/14/13），因此能校验
# 「修复后 (time,value) 配对没有被改错」——官方测试所有点值都是 1，校验不出。
#
# 覆盖点（对齐官方设计文档《数据修复功能》里的 4 类错误）：
#   ① 单个 Page 内点乱序 … A 相（生成器 mode=unsorted，t=+2,+3,+5,+4）
#   ① 单个 Page 内点**重复** … D 相（mode=dup，t=+2,+3,+3,+5）
#      · 修复语义 = **排序 + 去重**（同一序列同一时间戳只能有一个值）：
#        设计文档《数据修复功能》L94「…进行排序并去重后写入目标文件」；
#        实现 `RepairUnsortedFileCompactionWriter.endMeasurement():67-84`「remove duplicate timestamp and sort」
#      ⇒ **期望修复后 3 行**（= 修复前"不同时间戳"个数），**不是**修复前的查询行数 4 行
#        （判据：行数=去重时间戳数、时间集合不变、唯一时间戳的配对不变、配对不凭空新增）
#   ② Page 间乱序/重叠 … E 相（mode=pages，p1=[+2,+4]、p2=[+3,+5]）
#   ④ 顺序文件间 resource DeviceTimeIndex 重叠 … C 相（两个时间范围重叠的 seq 文件）
#   ③ Chunk/Page 统计信息错误 —— 需直接改 TsFile/`.resource` 二进制，本用例未构造（见 docs/CO33_CO34.md）
#   A 核心正向：load 未排序文件 → START REPAIR DATA → 修复链路日志 + 查询恢复升序 + 配对不变 + 目标落乱序区
#      · 日志证据（源码 i18n en/StorageEngineMessages.java）：
#        `[RepairScheduler] start check tsfile: {}`（扫描执行）
#        `[RepairScheduler] {} need to repair because it has internal unsorted data`（命中未排序判定）
#        `RepairUnsortedFileCompactionTask`（修复任务生成）
#        `[RepairScheduler] Repair task finished`（流程结束）
#      · 空间证据：`RepairUnsortedFileCompactionTask.generateTargetFile():144-151`（seq 源 → unsequence 目录）
#      · 进度证据：`system/repair/repair-data.progress`（`START_TIME`；`TSFILE` 行=无法修复的文件，应为 0）
#   B 开关对照：`enable_auto_repair_compaction=false` 时
#      · 不显式触发 → 60s 内**不会**被自动修复（修复链是显式/受控动作，不做"静默修复"）
#      · 显式 `START REPAIR DATA` → **仍然**修复（源码 `StorageEngine.repairData()`:695 只判只读与并发）
#   C 观察项：两个时间范围重叠的 seq 文件（auto_repair=false）+ 打开 seq 合并
#      → 记录是否出现待修复判定 / `CompactionValidationFailedException`（源码
#        `AbstractCompactionTask:543-557`：校验失败时开关=false 抛异常、=true 标 NEED_TO_CHECK）
#      → 最后仍用显式修复收口，断言最终有序
#
# 用法： bash co_repair_unsorted_load.sh [--consensus IoTConsensus] [--ver RCx]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_repair_unsorted_load_${DATA_CONSENSUS}"

DB=root.c33
DBOFF=root.c33off
DBOVL=root.c33ovl
DBDUP=root.c33dup
DBPAGE=root.c33page
NODE="$QDN"                                  # load 读的是该 DN 本地磁盘上的文件
RMT="${C33_REMOTE_DIR:-/tmp/c33gen}"
STAGE_A=/tmp/c33_stage_a
STAGE_B=/tmp/c33_stage_b
STAGE_C=/tmp/c33_stage_c
STAGE_D=/tmp/c33_stage_d
STAGE_E=/tmp/c33_stage_e
WAIT_A="${C33_REPAIR_WAIT_SEC:-180}"
WAIT_B="${C33_REPAIR_WAIT_SEC:-180}"
QUIET_SEC="${C33_QUIET_SEC:-60}"             # B 相"观察是否被自动修复"的静默窗口

# ---------------------------------------------------------------------------
# 证据基元
# ---------------------------------------------------------------------------
# 修复链日志计数：三个 DataNode 的 all + compaction 日志合计（两个 logger 都查）
c33_cnt(){ local pat=$1 h n s=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "cat $DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | grep -c -- '$pat'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done; echo "${s:-0}"; }
C33_PAT_CHECK='\[RepairScheduler\] start check tsfile'
C33_PAT_NEED='need to repair because'
C33_PAT_TASK='RepairUnsortedFileCompactionTask'
C33_PAT_DONE='\[RepairScheduler\] Repair task finished'
C33_PAT_VALID='CompactionValidationFailedException'
C33_PAT_UNSORTED='need to repair because it has internal unsorted data'
C33_PAT_OVERLAP='need to repair because it is overlapped'
c33_all_cnts(){ printf 'check=%s need=%s unsorted=%s overlap=%s task=%s done=%s valid=%s lasttime=%s stats=%s' \
  "$(c33_cnt "$C33_PAT_CHECK")" "$(c33_cnt "$C33_PAT_NEED")" "$(c33_cnt "$C33_PAT_UNSORTED")" \
  "$(c33_cnt "$C33_PAT_OVERLAP")" "$(c33_cnt "$C33_PAT_TASK")" "$(c33_cnt "$C33_PAT_DONE")" \
  "$(c33_cnt "$C33_PAT_VALID")" "$(c33_cnt "$C33_PAT_LASTTIME")" "$(c33_cnt "$C33_PAT_STATS")"; }

# SELECT 结果行（已去回显）
c33_rows(){ sq "select s1 from $1.d1;" 2>&1 | strip_echo | data_rows; }
# 升序标志：1=严格升序、0=存在逆序、E=无数据/查询失败
c33_asc(){ local out; out=$(c33_rows "$1" | awk -F'|' '{print $2}')
  [ -z "$out" ] && { echo E; return; }
  if [ "$(printf '%s\n' "$out" | sort)" = "$out" ]; then echo 1; else echo 0; fi; }
# 时间列原始顺序（用于把"乱序"直接打进日志当证据）
c33_times(){ c33_rows "$1" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); printf "%s ", $2} END{print ""}'; }
# 时间列**去重集合**（升序，形如 "t1 t2 t3 "）——用于"修复不丢任何不同时间戳"的判据
c33_tset(){ c33_rows "$1" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' | sort -u | tr '\n' ' '; }
# (time,value) 配对指纹（按时间升序），用于校验修复不改数据
c33_pairs(){ c33_rows "$1" | awk -F'|' '{t=$2; v=$3; gsub(/^[ \t]+|[ \t]+$/,"",t); gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s=%s;", t, v}' | tr ';' '\n' | sort | tr '\n' ';'; }
c33_nrows(){ c33_rows "$1" | wc -l | tr -d ' '; }
# 造一个未排序 TsFile：<stage> <device> [offsetMs] [valueBase] [unsorted|dup]
c33_gen(){ local stage=$1 dev=$2 off=${3:-0} vb=${4:-11} mode=${5:-unsorted} base out
  base=$(sshx "$NODE" 'date +%s%3N' | tr -dc '0-9')
  sshx "$NODE" "rm -rf $stage; mkdir -p $stage" >/dev/null 2>&1
  out=$(sshx "$NODE" "cd $RMT && java -cp $DB_DIR/lib/timechodb-server-2.0.12.1.jar:$DB_DIR/lib/common-dependency.jar:$RMT UnsortedTsFileGen $dev $stage $base $off $vb $mode" 2>&1 | tail -1)
  [ -n "$out" ] || out="(java 无输出)"
  log "    生成未排序 TsFile：$out（device=$dev base=$base offset=$off valueBase=$vb mode=$mode）"
  printf '%s' "$out"; }
# 顺序/乱序空间文件数（cmp_su 输出形如 "77:1/0 78:1/0 "，取合计）
c33_su(){ cmp_su "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | awk -F'[:/]' '{s+=$2; u+=$3} END{printf "seq=%d unseq=%d", s+0, u+0}'; }
c33_su_num(){ c33_su "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# 修复进度文件（源码 RepairLogger：system/repair 下 repair-data.(progress|stopped)）
c33_repair_log(){ local h f n
  for h in "${DN[@]}"; do
    f=$(sshx "$h" "find $DB_DIR/data/datanode/system/repair -maxdepth 1 -name 'repair-data*' 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
    if [ -n "$f" ]; then
      n=$(sshx "$h" "cat '$f' 2>/dev/null" 2>/dev/null)
      log "    [$h] 进度文件 ${f##*/}：$(printf '%s' "$n" | tr '\n' '|' | cut -c1-200)"
      printf '%s\n' "$n" | grep -q 'START_TIME' && pass "    [$h] 进度文件含 START_TIME（源码 RepairLogger 约定）" || fail "    [$h] 进度文件缺 START_TIME"
      local tf; tf=$(printf '%s\n' "$n" | grep -c '^TSFILE')
      [ "${tf:-0}" -eq 0 ] && pass "    [$h] 无 TSFILE 行 ⇒ 没有被判为『无法修复』的文件" || warn "    [$h] 进度文件记录了 $tf 个『无法修复』文件（需人工看）"
      return 0
    fi
  done
  fail "    三个节点都没找到 system/repair/repair-data*（修复任务未产生进度文件）"; }
# 修复扫描的两类判定异常（文件内乱序 vs 统计信息不符）
C33_PAT_LASTTIME='CompactionLastTimeCheckFailedException'
C33_PAT_STATS='CompactionStatisticsCheckFailedException'
c33_mkdb(){ sq "create database $1;" >/dev/null 2>&1
  # 不显式指定编码：INT32 默认 RLE，与生成器 `new MeasurementSchema("s1", INT32)` 一致
  local r; r=$(sq "create timeseries $1.d1.s1 with datatype=INT32;" 2>&1)
  printf '%s' "$r" | grep -qE 'successfully|already' && pass "  $1.d1.s1 时序就绪" || fail "  $1.d1.s1 创建失败: $(printf '%s' "$r" | tail -1)"; }
c33_load(){ local stage=$1 resp; resp=$(sq "load '$stage';" 2>&1)
  log "    load '$stage' → $(printf '%s' "$resp" | strip_echo | tail -1)"
  printf '%s' "$resp"; }
c33_repair(){ local resp; resp=$(sq "start repair data;" 2>&1)
  log "    START REPAIR DATA → $(printf '%s' "$resp" | strip_echo | tail -1)"
  assert_not_contains "  START REPAIR DATA 受理无报错" "$(printf '%s' "$resp" | strip_echo)" 'Error|error|Exception|EXECUTE_STATEMENT_ERROR'; }
# 轮询直到升序恢复
c33_wait_asc(){ local db=$1 win=$2 dl flag=""
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do flag=$(c33_asc "$db"); [ "$flag" = 1 ] && break; sleep 2; done
  echo "${flag:-E}"; }

log "--- 0) 集群准备：三类合并先关；auto_repair=true；candidate=2 ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},enable_auto_repair_compaction=true" cmp_cluster_prepare
assert_eq "  enable_auto_repair_compaction 生效值" "$(cmp_eff "${DN[0]}" enable_auto_repair_compaction)" "true"

log "--- 1) 编译并分发未排序 TsFile 生成器（用服务端自带 jar）---"
GEN_DIR=$(V_TESTDB="$V_TESTDB" GEN_TARGET_NODE="$NODE" GEN_REMOTE_DIR="$RMT" bash "$TTL_SKILL_DIR/assets/unsorted/build_gen.sh" 2>>"$OUT") || fail "  生成器编译/分发失败"
[ -n "${GEN_DIR:-}" ] && log "    编译目录：$GEN_DIR，目标节点：$NODE:$RMT"

# ===========================================================================
# A 相：核心正向 —— 未排序 TsFile + load + START REPAIR DATA
# ===========================================================================
log "=== A 相：未排序文件 load → 修复链路（auto_repair=true）==="
C0=$(c33_all_cnts); log "  A 修复链基线：$C0"
c33_mkdb "$DB"
A_FILE=$(c33_gen "$STAGE_A" "$DB.d1")
[ -n "$A_FILE" ] && pass "  生成器执行成功" || fail "  生成器执行失败"
A_LOAD=$(c33_load "$STAGE_A")
assert_not_contains "  load 无报错" "$(printf '%s' "$A_LOAD" | strip_echo)" 'Error|error|Exception|Failed|failed'
P_A0=$(c33_pairs "$DB"); N_A0=$(c33_nrows "$DB"); F_A0=$(c33_asc "$DB")
log "  load 后：行数=$N_A0 升序标志=$F_A0（1=升序）"
log "  load 后时间列原始顺序：$(c33_times "$DB")"
assert_eq "  [场景有效性] load 后查到 4 行" "$N_A0" "4"
assert_eq "  [场景有效性] load 后数据确实**乱序**（升序标志=0）" "$F_A0" "0"
[ "$N_A0" = "4" ] && [ "$F_A0" = "0" ] || warn "  A 相场景未成立（行数=$N_A0 升序标志=$F_A0），后续判定仅供参考"
A_SU0=$(c33_su "$DB"); log "  A load 后空间分布：$A_SU0（load 的文件进顺序区）"

c33_repair
F_A1=$(c33_wait_asc "$DB" "$WAIT_A")
sleep 5
C1=$(c33_all_cnts); log "  A 修复链计数：$C0 → $C1"
assert_eq "  A 修复后 SELECT 恢复严格升序" "$F_A1" "1"
assert_eq "  A 修复后行数不变" "$(c33_nrows "$DB")" "$N_A0"
assert_eq "  A 修复前后 (time,value) 配对不变" "$(c33_pairs "$DB")" "$P_A0"
pass "  A 修复后时间列：$(c33_times "$DB")"
c33_delta(){ local a=$1 b=$2 k=$3 x y; x=$(printf '%s' "$a" | sed -E "s/.*$k=([0-9]+).*/\1/"); y=$(printf '%s' "$b" | sed -E "s/.*$k=([0-9]+).*/\1/"); echo $(( ${y:-0} - ${x:-0} )); }
D_CHECK=$(c33_delta "$C0" "$C1" check); D_NEED=$(c33_delta "$C0" "$C1" need)
D_TASK=$(c33_delta "$C0" "$C1" task);  D_DONE=$(c33_delta "$C0" "$C1" done)
D_UNS=$(c33_delta "$C0" "$C1" unsorted); D_OVL=$(c33_delta "$C0" "$C1" overlap)
log "  A 增量：start_check=$D_CHECK need=$D_NEED (unsorted=$D_UNS overlap=$D_OVL) task=$D_TASK done=$D_DONE"
[ "${D_CHECK:-0}" -ge 1 ] && pass "  A 修复扫描执行（[RepairScheduler] start check tsfile +$D_CHECK）" || fail "  A 未执行修复扫描"
[ "${D_NEED:-0}" -ge 1 ] && pass "  A 命中待修复判定（need to repair because … +$D_NEED）" || fail "  A 未判定出待修复文件"
[ "${D_TASK:-0}" -ge 1 ] && pass "  A 生成 RepairUnsortedFileCompactionTask（+$D_TASK）" || fail "  A 未生成修复任务"
[ "${D_DONE:-0}" -ge 1 ] && pass "  A 修复流程结束（[RepairScheduler] Repair task finished +$D_DONE）" || warn "  A 未见 Repair task finished（可能仍在收尾）"

# 设计文档《数据修复功能》+ RC7 源码 `RepairUnsortedFileCompactionTask.generateTargetFile():144-151`
#   源码注释：`if source file is sequence, the sequence data targetFileDir should be replaced to unsequence`
#   ⇒ 顺序区的待修复文件修完后，目标文件必须落在 **乱序区**
A_SU1=$(c33_su "$DB"); log "  A 修复后空间分布：$A_SU0 → $A_SU1"
A_S1=$(printf '%s' "$A_SU1" | sed -n 's/.*seq=\([0-9]*\).*/\1/p')
A_U1=$(printf '%s' "$A_SU1" | sed -n 's/.*unseq=\([0-9]*\).*/\1/p')
[ "${A_U1:-0}" -ge 1 ] && pass "  A 修复目标写入**乱序区**（源码 L144-151：seq 源 → unsequence 目录）" \
  || fail "  A 修复后乱序区仍为空（与源码 L144-151 不符）"
[ "${A_S1:-9}" -eq 0 ] && pass "  A 原待修复文件已从顺序区移除（seq=0）" \
  || warn "  A 顺序区仍有 ${A_S1:-?} 个文件（可能是同库其它正常文件）"
c33_repair_log
D_LT=$(c33_delta "$C0" "$C1" lasttime); D_ST=$(c33_delta "$C0" "$C1" stats)
log "  A 判定分支增量：LastTimeCheckFailed=$D_LT（文件内乱序/重复） StatisticsCheckFailed=$D_ST（统计信息不符）"
[ $(( ${D_LT:-0} + ${D_ST:-0} )) -ge 1 ] && pass "  A 逐级检查命中（乱序 $D_LT / 统计 $D_ST）" \
  || warn "  A 未见两类判定异常日志（判定发生在行内、可能不打日志，已按日志证据如实记录）"

# ===========================================================================
# B 相：开关对照（auto_repair=false）
# ===========================================================================
log "=== B 相：enable_auto_repair_compaction=false 对照 ==="
cmp_set_hot enable_auto_repair_compaction false >/dev/null
assert_eq "  B enable_auto_repair_compaction 生效值" "$(cmp_eff "${DN[0]}" enable_auto_repair_compaction)" "false"
B0=$(c33_all_cnts)
c33_mkdb "$DBOFF"
c33_gen "$STAGE_B" "$DBOFF.d1" >/dev/null
B_LOAD=$(c33_load "$STAGE_B")
assert_not_contains "  B load 无报错" "$(printf '%s' "$B_LOAD" | strip_echo)" 'Error|error|Exception|Failed|failed'
P_B0=$(c33_pairs "$DBOFF"); N_B0=$(c33_nrows "$DBOFF"); F_B0=$(c33_asc "$DBOFF")
log "  B load 后：行数=$N_B0 升序标志=$F_B0"
assert_eq "  [场景有效性] B load 后查到 4 行" "$N_B0" "4"
assert_eq "  [场景有效性] B load 后数据确实乱序" "$F_B0" "0"
cmp_set_hot enable_seq_space_compaction true >/dev/null   # 打开正常合并，走"自动"路径
log "  B 静默观察 ${QUIET_SEC}s（未发 START REPAIR DATA，auto_repair=false，正常合并已开）..."
sleep "$QUIET_SEC"
B1=$(c33_all_cnts); log "  B 修复链计数：$B0 → $B1"
DB_TASK=$(c33_delta "$B0" "$B1" task); DB_NEED=$(c33_delta "$B0" "$B1" need); DB_VALID=$(c33_delta "$B0" "$B1" valid)
log "  B 增量：need=$DB_NEED task=$DB_TASK CompactionValidationFailedException=$DB_VALID"
assert_eq "  B 未显式触发时**不会**自动修复（无 RepairUnsortedFileCompactionTask 增量）" "${DB_TASK:-0}" "0"
assert_eq "  B 静默窗口后数据仍乱序（没有被静默修掉）" "$(c33_asc "$DBOFF")" "0"

log "  B2：auto_repair=false 下**显式** START REPAIR DATA（源码 repairData():695 只判只读/并发）"
c33_repair
F_B2=$(c33_wait_asc "$DBOFF" "$WAIT_B")
sleep 5
B2=$(c33_all_cnts); DB2_TASK=$(c33_delta "$B1" "$B2" task); DB2_NEED=$(c33_delta "$B1" "$B2" need)
log "  B2 增量（相对 B1）：need=$DB2_NEED task=$DB2_TASK"
assert_eq "  B2 显式修复仍然生效（auto_repair=false 只影响自动选择路径）" "$F_B2" "1"
assert_eq "  B2 修复后行数不变" "$(c33_nrows "$DBOFF")" "$N_B0"
assert_eq "  B2 修复前后 (time,value) 配对不变" "$(c33_pairs "$DBOFF")" "$P_B0"
[ "${DB2_TASK:-0}" -ge 1 ] && pass "  B2 生成修复任务（+$DB2_TASK）" || fail "  B2 未生成修复任务"

# ===========================================================================
# C 相（观察项）：两个时间范围重叠的 seq 文件 + 打开 seq 合并（auto_repair=false）
# ===========================================================================
log "=== C 相（观察）：重叠 seq 文件下的自动选择路径 ==="
C0b=$(c33_all_cnts)
c33_mkdb "$DBOVL"
cmp_set_hot enable_seq_space_compaction false >/dev/null
c33_gen "$STAGE_C" "$DBOVL.d1" 0 11 >/dev/null
c33_gen "$STAGE_C" "$DBOVL.d1" 2 21 >/dev/null      # 时间范围 +4..+7，与前一个 +2..+5 重叠
C_LOAD=$(c33_load "$STAGE_C")
assert_not_contains "  C load 无报错" "$(printf '%s' "$C_LOAD" | strip_echo)" 'Error|error|Exception|Failed|failed'
log "  C load 后文件数=$(cmp_all_sum "$DBOVL") 布局=$(cmp_lay "$DBOVL") 升序标志=$(c33_asc "$DBOVL")"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 45
C1b=$(c33_all_cnts); log "  C 修复链计数：$C0b → $C1b（45s 观察窗）"
DC_NEED=$(c33_delta "$C0b" "$C1b" need); DC_TASK=$(c33_delta "$C0b" "$C1b" task); DC_VALID=$(c33_delta "$C0b" "$C1b" valid)
DC_OVL=$(c33_delta "$C0b" "$C1b" overlap); DC_UNS=$(c33_delta "$C0b" "$C1b" unsorted)
log "  C 观察结果（auto_repair=false）：need=$DC_NEED (overlap=$DC_OVL unsorted=$DC_UNS) task=$DC_TASK CompactionValidationFailedException=$DC_VALID 升序标志=$(c33_asc "$DBOVL")"
if [ "${DC_TASK:-0}" -gt 0 ]; then
  warn "  C 观察：auto_repair=false 仍出现了 $DC_TASK 个修复任务（记录，待与研发确认）"
elif [ "${DC_VALID:-0}" -gt 0 ]; then
  pass "  C 观察：如源码预期——auto_repair=false 时重叠校验失败抛 CompactionValidationFailedException（+$DC_VALID），不静默修复"
else
  warn "  C 观察：45s 内既无修复任务也无校验失败（可能该分区未进入合并选择）"
fi
c33_repair
C_SU0=$(c33_su "$DBOVL")
F_C=$(c33_wait_asc "$DBOVL" "$WAIT_B")
assert_eq "  C 显式修复后恢复升序" "$F_C" "1"
[ "$(c33_nrows "$DBOVL")" -ge 4 ] && pass "  C 修复后仍有 ≥4 行（重叠点被合并去重，属预期）" || fail "  C 修复后行数不足：$(c33_nrows "$DBOVL")"
# 文件间重叠的修复语义（设计文档：重叠文件通过合并任务「移动到乱序区」；权威实现是硬链接
# `RepairUnsortedFileCompactionPerformer.prepareTargetFile()` → `FileUtils.createLink(..., true)`）
C_SU1=$(c33_su "$DBOVL"); log "  C 空间分布：$C_SU0 → $C_SU1（重叠修复应把文件移出顺序区）"
CS0=$(printf '%s' "$C_SU0" | sed -n 's/seq=\([0-9]*\).*/\1/p'); CS1=$(printf '%s' "$C_SU1" | sed -n 's/seq=\([0-9]*\).*/\1/p')
CU1=$(printf '%s' "$C_SU1" | sed -n 's/.*unseq=\([0-9]*\).*/\1/p')
[ "${CU1:-0}" -ge 1 ] && pass "  C 重叠文件已移入乱序区（unseq=$CU1 ⇒ 顺序区重叠被消除）" \
  || fail "  C 乱序区仍为空：顺序区重叠没有被修复消除"
[ "${CS1:-9}" -lt "${CS0:-0}" ] && pass "  C 顺序区文件数下降（$CS0 → $CS1）" \
  || warn "  C 顺序区文件数未下降（$CS0 → $CS1），重叠可能以其它方式消除，已记录"

# ===========================================================================
# D 相：重复时间戳（设计文档「单个 Page 内的点乱序**或重复**」）
# ===========================================================================
log "=== D 相：重复时间戳文件（t=+2,+3,+3,+5）==="
D0b=$(c33_all_cnts)
c33_mkdb "$DBDUP"
D_FILE=$(c33_gen "$STAGE_D" "$DBDUP.d1" 0 31 dup)
D_LOAD=$(c33_load "$STAGE_D")
assert_not_contains "  D load 无报错" "$(printf '%s' "$D_LOAD" | strip_echo)" 'Error|error|Exception|Failed|failed'
D_N0=$(c33_nrows "$DBDUP"); D_P0=$(c33_pairs "$DBDUP")
D_T0=$(c33_tset "$DBDUP")                                    # 修复前时间集合（升序去重）
D_NE=$(printf '%s\n' "$D_T0" | tr ' ' '\n' | grep -c .)      # 修复前**不同**时间戳个数 = 修复后期望行数
# 修复前只出现一次的时间戳（这些点没有重复，修复后必须原样保留）
D_UNIQ=$(printf '%s' "$D_P0" | tr ';' '\n' | sed -n 's/^\([^=]*\)=.*/\1/p' \
         | sort | uniq -c | awk '$1==1{print $2}' | tr '\n' ' ')
log "  D load 后行数=$D_N0 不同时间戳数=$D_NE（文件内 4 个点、其中 1 个时间戳重复）时间列=$(c33_times "$DBDUP")"
log "  D 修复前时间集合（去重升序）=$D_T0"
log "  D 修复前 (time,value) 配对=$D_P0"
log "  D 修复前唯一时间戳（这些点的配对修复后必须原样保留）=${D_UNIQ:-none}"
[ "${D_N0:-0}" -ge 3 ] && pass "  [场景有效性] D 相查到 ≥3 行" || fail "  [场景有效性] D 相仅 $D_N0 行"
c33_repair
F_D=$(c33_wait_asc "$DBDUP" "$WAIT_B")
sleep 5
D1b=$(c33_all_cnts); DD_TASK=$(c33_delta "$D0b" "$D1b" task); DD_LT=$(c33_delta "$D0b" "$D1b" lasttime); DD_ST=$(c33_delta "$D0b" "$D1b" stats)
D_N1=$(c33_nrows "$DBDUP"); D_T1=$(c33_tset "$DBDUP"); D_AFTER=$(c33_pairs "$DBDUP")
log "  D 修复链增量：task=$DD_TASK LastTimeCheckFailed=$DD_LT StatisticsCheckFailed=$DD_ST；行数 $D_N0 → $D_N1（不同时间戳 $D_NE）"
log "  D 修复后时间列=$(c33_times "$DBDUP")"
log "  D 修复后时间集合（去重升序）=$D_T1"
log "  D 修复后 (time,value) 配对=$D_AFTER"
assert_eq "  D 修复后可查询（非空且时间列非降）" "$F_D" "1"
# 修复语义 = 排序 + 去重：文件内同一时间戳的多个点合并为 1 个（同一序列同一时间戳只能有一个值）
#   依据：设计文档《数据修复功能》L94「…保存在内存中的一个 List，进行排序并去重后写入目标文件」
#        + RepairUnsortedFileCompactionWriter.endMeasurement():67-84「remove duplicate timestamp and sort」
#   ⇒ 期望行数 = 修复前**不同时间戳**个数（$D_NE），**不是**修复前的查询行数（$D_N0）
assert_eq "  D 修复后行数 = 修复前不同时间戳数（排序+去重语义）" "$D_N1" "$D_NE"
assert_eq "  D 修复后时间集合与修复前完全一致（不丢任何不同时间戳）" "$D_T1" "$D_T0"
# 有牙①：修复前只出现一次的时间戳，其 (time,value) 配对必须原样还在（值没被改错/丢掉）
D_LOST=""
for t in $D_UNIQ; do case "$D_AFTER" in *"$t="*) ;; *) D_LOST="$D_LOST $t";; esac; done
assert_eq "  D 修复前唯一时间戳的 (time,value) 配对在修复后仍在" "${D_LOST:-none}" "none"
# 有牙②：修复后每一行都必须来自修复前（不得凭空造值/错配；重复时间戳上留下的只能是原来两个值之一）
D_INVENTED=$(LC_ALL=C comm -13 <(printf '%s' "$D_P0" | tr ';' '\n' | sed '/^$/d' | LC_ALL=C sort) \
                            <(printf '%s' "$D_AFTER" | tr ';' '\n' | sed '/^$/d' | LC_ALL=C sort) | wc -l | tr -d ' ')
assert_eq "  D 修复后无凭空新增的 (time,value)" "$D_INVENTED" "0"
# 证据补强：把修复后的时间列与配对打进日志（原来 D 相只打行数，是证据缺口）
pass "  D 修复后时间列/配对（证据）：$(c33_times "$DBDUP")| $D_AFTER"
[ "${DD_TASK:-0}" -ge 1 ] && pass "  D 重复时间戳文件也走了修复链路（task +$DD_TASK）" || fail "  D 未生成修复任务"
if [ "${D_N0:-0}" -gt "${D_NE:-0}" ]; then
  [ "${D_N1:-0}" = "${D_NE:-0}" ] \
    && pass "  D 修复前查询层未去重（$D_N0 行 / $D_NE 个不同时间戳），修复后 $D_N1 行 ⇒ 文件层『排序+去重』生效" \
    || warn "  D 修复后 $D_N1 行 ≠ 不同时间戳数 $D_NE（上面第 1 条断言已判 FAIL，此处仅记录）"
else
  warn "  D 查询层已对重复时间戳去重（修复前 $D_N0 行 = $D_NE 个不同时间戳）⇒ 文件层『排序+去重』只能由日志与空间分布佐证"
fi
D_SU=$(c33_su "$DBDUP"); D_U1=$(printf '%s' "$D_SU" | sed -n 's/.*unseq=\([0-9]*\).*/\1/p')
[ "${D_U1:-0}" -ge 1 ] && pass "  D 修复目标同样写入乱序区（$D_SU）" || warn "  D 乱序区为空（记录：$D_SU）"
# ===========================================================================
# E 相：Page 间乱序/重叠（设计文档《数据修复功能》错误类型②「Page 间乱序或重叠」）
#   生成器 mode=pages：p1=[+2,+4]、p2=[+3,+5] —— 每个 Page 内部有序，
#   但 p2 的起点(+3) 早于 p1 的终点(+4) ⇒ 跨 Page 乱序。
#   源码判定：`RepairDataFileScanUtil.validateTimeData()` 用**同一个** `previousTime`
#   字段跨 Page 比较（`checkPreviousTimeAndUpdate`）⇒ p2 首个点 3 ≤ 4 即抛
#   `CompactionLastTimeCheckFailedException`。
# ===========================================================================
log "=== E 相：Page 间乱序/重叠文件（mode=pages）==="
E0=$(c33_all_cnts)
c33_mkdb "$DBPAGE"
E_FILE=$(c33_gen "$STAGE_E" "$DBPAGE.d1" 0 41 pages)
E_LOAD=$(c33_load "$STAGE_E")
assert_not_contains "  E load 无报错" "$(printf '%s' "$E_LOAD" | strip_echo)" 'Error|error|Exception|Failed|failed'
E_N0=$(c33_nrows "$DBPAGE"); E_F0=$(c33_asc "$DBPAGE"); E_P0=$(c33_pairs "$DBPAGE")
log "  E load 后：行数=$E_N0 升序标志=$E_F0 时间列=$(c33_times "$DBPAGE")"
assert_eq "  [场景有效性] E 相 4 行" "$E_N0" "4"
# 场景有效性改为「构造证明」：pages 模式由生成器确定写出跨页乱序（页1 时间=[+2,+4]、页2=[+3,+5]）。
# ⚠️ 不能用 SELECT 的「升序标志」当代理判据 —— 读路径会把跨页乱序归一成时间升序
#    （本相实测 E_F0=1，正是 2026-10-16 V1/V2 双双 fail=11 里那条误判的根源，详见 _scratch/CO33_TRIAGE.md §3）。
pass "  [场景有效性] E 相文件由生成器 pages 模式构造（跨页乱序为构造保证；SELECT 升序代理=$E_F0 不可靠，仅记录）"
c33_repair
E_F1=$(c33_wait_asc "$DBPAGE" "$WAIT_B")
sleep 5
E1=$(c33_all_cnts); DE_TASK=$(c33_delta "$E0" "$E1" task); DE_LT=$(c33_delta "$E0" "$E1" lasttime); DE_ST=$(c33_delta "$E0" "$E1" stats)
log "  E 修复链增量：task=$DE_TASK LastTimeCheckFailed=$DE_LT StatisticsCheckFailed=$DE_ST"
log "  E 修复后 SELECT 严格升序代理=$E_F1（读路径会归一化，本判据仅供参考，不作硬判；硬判据是下面的 DE_TASK）"
assert_eq "  E 修复后行数不变" "$(c33_nrows "$DBPAGE")" "$E_N0"
assert_eq "  E 修复前后 (time,value) 配对不变" "$(c33_pairs "$DBPAGE")" "$E_P0"
[ "${DE_TASK:-0}" -ge 1 ] && pass "  E Page 间乱序文件走了修复链路（task +$DE_TASK）" || fail "  E 未生成修复任务"

C_PROG=$(sq "show repair data partition table progress;" 2>&1 | strip_echo | table_rows | head -3 | tr '\n' ' ')
log "  （观测）SHOW REPAIR DATA PARTITION TABLE PROGRESS：${C_PROG:-（无输出/不支持）}"

log "--- 收尾三件套 ---"
post_checks "select s1 from ${DB}.d1;" tree
cmp_case_finish "" tree ""
