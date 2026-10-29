#!/bin/bash
# ============================================================================
# CR-11 OBJECT 手动删除（整表 / 部分时间范围 / 整库删除）—— 表模型
#   覆盖需求点：R-34（问题域）、R-46（不新增语法即可删 OBJECT）、R-47（删除后 OBJECT 真实
#              存储内容随之删除）、R-49（dataRegion 写锁 / WAL / object 目录定位）、
#               R-50（删全表=物理删表目录；非全表=遍历 .bin/.tmp 逐文件判定删除）、
#               R-51（删 database：删 object 目录下该 region 的全部文件与目录）
#   规格出处：crud_skill/docs/REQ_MATRIX.md §3 CR-11（判据草案）+ §1 R-34/R-46/R-47/R-49/
#             R-50/R-51 逐字原文；§2 映射表；§5 去重口径。
#
# ---------------------------------------------------------------------------
# 【与 compaction_skill CO-41 的严格去重（必读，否则会把正常 GC 删除误判成缺陷）】
#   CO-41（compaction_skill/cases/common/co_object_ttl.sh）已覆盖：
#     · object 目录形态 `data/datanode/data/object/<regionId>/<base32(table)>[/tags]/{pointTime}_{tsVersion}.bin`
#     · 「合并/ TTL 清理只删 TTL 过期的 object，不删 deletion 删除的」（D7-2）
#     · **TTL 路径（CompactionUtils）删除计数** ↑ 而 **GC 路径（DataNodeObjectFileService）删除计数** 必须不变
#     · object 目录计数 helper（全局 .bin 计数 / 按 region 精确计数 / 按文件名 pointTime 逐点计数）
#   ⇒ 本用例**反过来**用同一套口径：
#     · 断言 **GC 路径（删除触发的 ObjectGC）删除计数 ↑**，而 **TTL 路径（CompactionUtils）删除计数恒为 0**
#       （本用例所有表 TTL 均为 INF，TTL 检查线程不会删任何 object）；
#     · 不复述 CO-41 的「合并不删 deletion 的 object」（那需要合并窗口，CO-41 已做）；
#     · 不复述 CO-06 的 DROP TABLE/DROP DATABASE 后**元数据不复活**（元数据面）；
#       本用例只做**物理面**：object 真实文件是否被清理 + 查询是否查不到 + 隔离性。
#   详细的采集口径注释见下面 helper 段（逐条标注复用自 CO-41 的哪一段）。
#
# ---------------------------------------------------------------------------
# 【RC7 现场机制（源码基线 D:\IDEA\timechodb_src\v20121\timechodb，git HEAD 67bb5ced2b）】
#   ① **整表删除先墓碑改名，再异步回收**：DataRegion.deleteByTable →
#      `TierManager.getAllMatchedObjectDirs` → `ObjectDirectoryScanner.renameTableDirForDrop`
#      （:3351-3362，把活的表目录改名为 `<object>/<regionId>/.iotdb-objectgc/<taskId>-<表目录名>`，
#        `ObjectDirectoryScanner.java:58` `OBJECT_GC_TOMBSTONE_DIR=".iotdb-objectgc"`、`:323` 实现）
#      → `unlinkMatchingTempAndBack`（:3384-3390，只清 .tmp/.back）→
#      `enqueueObjectGcAfterSealedDelete`（:3407，`ObjectGcJournal.append`）⇒ **.bin 的物理删除由
#      独立 GC 线程（ObjectGcWorker / ObjectDirectoryScanner.scanAndDelete）异步完成**。
#   ② 非整表删除（带时间范围）：不改名，直接按 TableDeletionEntry（谓词+时间段）扫描目录，
#      满足条件才物理删（R-50 后半句）。
#   ③ 删除日志：
#      · `log_datanode_object_deletion.log`（logger 名 `OBJECT_DELETION`，IoTDBConstant.java:150；
#        appender 见 iotdb-core/datanode/src/assembly/resources/conf/logback-datanode.xml:195）
#      · 成功删文件：`Remove object file {}, size is {}(byte)`（StorageEngineMessages.java:242 /
#        DataNodeMiscMessages.REMOVE_OBJECT_FILE）——**同步 (deleteObjectFile) 与异步 GC
#        (deleteObjectFileForGc) 都会打这一行**，因此靠行内的 logger/类名区分路径：
#        `DataNodeObjectFileService` = 删除触发的 GC 路径；`CompactionUtils` = TTL 检查路径。
#      · 失败：`Failed to remove object file {}`（StorageEngineMessages.java:237，
#        DataNodeObjectFileService 同步路径）、`Failed to delete object file {} during object GC`
#        （StorageEngineMessages.java:1611，ObjectGcWorker，落在 log_datanode_all.log）。
#   ④ object 文件名形如 `{pointTime}_{tsVersion}.bin` ⇒ **可按 pointTime 逐点判定**
#      「该删的删了、不该删的还在」（与 CO-41 D7-4 同族语义；本用例用"时间段"做归属划分）。
#
# ---------------------------------------------------------------------------
# 【判据（硬判 / WARN 分开列）】
#   硬判（fail）：
#     H1 场景有效性：OBJECT 数据确实写成功、磁盘上确实生成 object 真实文件（+0 即场景未成立）；
#     H2 部分删除：被删时间段的行查不到（行数 = 期望）**且** 该时间段 object 真实文件数 → 0；
#     H3 部分删除：未删时间段 / 同库另一张表 / 另一库的 object 真实文件数**完全不变**（隔离性）；
#     H4 整表删除（`DELETE FROM t`，无 WHERE ⇒ TableDeletionEntry.isDroppingTable()=true）：
#         行数 → 0 **且** 该表 object 真实文件数 → 0（墓碑改名 + 异步 GC 完成）；
#     H5 整库删除（`DROP DATABASE`）：该 database 对应 region 的 object 真实文件数 → 0（R-51）；
#     H6 全程 `log_datanode_object_deletion.log` 的 `Failed to remove object file` /
#         `Failed to list object directory` 计数**不得增加**（矩阵"双信号①"）；
#         `log_datanode_all.log` 的 `Failed to delete object file ... during object GC` 也不得增加；
#     H7 **"逻辑删除"失败模式**：查询已空但磁盘 object 仍残留（数量不降）⇒ 判 FAIL（这正是 R-47 的失败模式）；
#     H8 收尾三件套（sync lag / 逐个停 DN 副本一致 / CN-DN 日志扫异常）—— 由 post_checks 完成。
#   WARN（不可观测/可能退化，只记录证据）：
#     W1 object 文件与"点数 × 副本数"不是 1:1 ⇒ 理论值判据降级，只看"相对基线的变化"；
#     W2 墓碑目录 `.iotdb-objectgc` 在轮询窗口内没被观测到（GC 太快）⇒ 只记录，不判缺陷；
#     W3 GC 路径删除日志无增量但文件数确实下降 ⇒ 记录（日志轮转/logger 归属差异），不单独判缺陷。
#
# 【不可构造 / 不覆盖】见 docs/REQ_MATRIX.md §4-B（R-16/17/18 共享 mod 文件等与本用例无关）与 §4-D
#   （Object 导入导出整篇为模板占位、源码零实现 ⇒ 无 R-xx 可测）。R-48（"对已有功能没有负面性能
#   影响"）由 CR-12 的开销对照弱判据覆盖；R-52（单文件删除异常跳过 + 客户端报错）在 CR-12。
#
# 用法： bash cases/common/cr_object_manual_delete.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：约 15~22 分钟（8 个阶段动作 + 3 次异步 GC 等待窗口 + 收尾三件套停/起 3 个 DN）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_object_manual_delete_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 规模与配置（全部可被环境变量覆盖；放在文件顶部，便于按环境伸缩）
# ---------------------------------------------------------------------------
DB=${CR11_DB:-cro11}              # 目标库（表模型；库名即数据目录名）
DBK=${CR11_DBK:-cro11b}           # 隔离库（全程不删，用于"整库删除不影响其它库"的硬判据）
T1=${CR11_T1:-t1}                 # 目标表（被部分删 + 整表删）
T2=${CR11_T2:-t2}                 # 同库另一张表（隔离性硬判据）
TK=${CR11_TK:-tk}                 # 隔离库里的表
DEVS=${CR11_DEVS:-3}              # 目标表设备数
ROWS=${CR11_ROWS:-8}              # 每设备每批点数
DEVS2=${CR11_DEVS2:-2}            # 同库另一张表 / 隔离库的设备数
ROWS2=${CR11_ROWS2:-6}            # 同上，点数
HOLD_MS=${CR11_HOLD_MS:-20000}    # 批次 A 与批次 B 的时间间隔（必须 > ROWS*10，保证 T_CUT 精确切分）
OBJ_WIN=${CR11_OBJ_WIN:-150}      # 等异步 ObjectGC 完成的窗口（秒）
STABLE_W=${CR11_STABLE_W:-30}     # 等 object 文件数稳定的上限（秒）

# ---------------------------------------------------------------------------
# object / 日志 helper（采集口径复用自 CO-41：co_object_ttl.sh 的 c41_obj_* / c41_del_*，
#   见该文件 :96-137；此处只改前缀并补"按时间段计数"，一律在本地 awk 过滤，
#   避免把 `$1` 塞进远端命令被远端 shell 二次展开——本项目在远端 awk 上踩过静默算 0 的坑）
# ---------------------------------------------------------------------------
# 所有 DN 上全部 object 真实文件（.bin/.tmp/.back 都算；与 CO-41 同口径）
cr11_obj_names(){ local h
  for h in "${DN[@]}"; do
    sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' -printf '%f\n' 2>/dev/null" 2>/dev/null | tr -d '\r'
  done; }
cr11_obj_all(){ cr11_obj_names | grep -c . ; }
# 文件名里的 pointTime（`{pointTime}_{tsVersion}.bin` → 第一段）；非数字行直接丢弃
cr11_obj_times(){ cr11_obj_names | cut -d_ -f1 | grep -E '^[0-9]+$'; }
# 落在 [lo,hi] 时间段内的 object 真实文件数（逐点判定用）
cr11_range_cnt(){ local lo=$1 hi=$2
  cr11_obj_times | awk -v a="$lo" -v b="$hi" '{ if ($1+0 >= a && $1+0 <= b) c++ } END { print c+0 }'; }
# 等 object 总数稳定（连续两次采样相同）；CO-41 同口径（:100-108）
cr11_obj_stable(){ local w=${1:-40} dl a b
  dl=$(( $(date +%s) + w )); a=$(cr11_obj_all); b=$a
  while (( $(date +%s) < dl )); do
    sleep 5; b=$(cr11_obj_all)
    [ "${b:-0}" = "${a:-0}" ] && { echo "${b:-0}"; return 0; }
    a=$b
  done
  echo "${b:-0}"; }
# 某库的 region 目录名（复用 lib/common.sh 的 ttl_region_ids）
# 某库全部 region 的 object 真实文件数（按 "*object*/<regionId>/" 路径匹配；对目录层级变化更宽容）
cr11_obj_db_node(){ local h=$1 db=$2 rid v s=0
  for rid in $(ttl_region_ids "$h" "$db"); do
    v=$(sshx "$h" "find $DB_DIR/data -path '*object*/$rid/*' -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done
  echo "${s:-0}"; }
cr11_obj_db_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr11_obj_db_node "$h" "$1") )); done; echo "${s:-0}"; }
# 删除日志按路径分类（**必须分开数**，否则会把 GC 的正常删除误判成缺陷；CO-41 :131-137）
cr11_del_node(){ local h=$1 pat=$2 v
  v=$(sshx "$h" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | grep -c '$pat'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
cr11_del_gc_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr11_del_node "$h" 'DataNodeObjectFileService') )); done; echo "${s:-0}"; }
cr11_del_ttl_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr11_del_node "$h" 'CompactionUtils') )); done; echo "${s:-0}"; }
# 失败计数（三种文案一次性取回，避免多次 ssh）
cr11_fail_snapshot(){ local h out="" v1 v2 v3
  for h in "${DN[@]}"; do
    v1=$(sshx "$h" "grep -hc 'Failed to remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    v2=$(sshx "$h" "grep -hc 'Failed to delete object file' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    v3=$(sshx "$h" "grep -hc 'Failed to list object directory' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    out="$out${h##*.}:remove=${v1:-0},gc=${v2:-0},list=${v3:-0} "
  done; printf '%s' "$out"; }
# 某库的 region 的 object 根目录（用于墓碑/表目录观测；找不到就返回空）
cr11_region_dir(){ local h=$1 rid=$2
  sshx "$h" "find $DB_DIR/data -type d -path '*object*/$rid' 2>/dev/null | head -1" 2>/dev/null | tr -d '\r'; }
# 该 region 下的一级目录清单（表目录 + .iotdb-objectgc 墓碑）
cr11_region_ls(){ local h=$1 rid=$2 d
  d=$(cr11_region_dir "$h" "$rid")
  [ -n "$d" ] || { echo "<region 目录不存在>"; return; }
  sshx "$h" "ls -1 '$d' 2>/dev/null | tr '\n' ','" 2>/dev/null | tr -d '\r'; }

# 表模型建库 + OBJECT 表（语法来自 CO-41 :140-147：dev TAG / v FIELD / o OBJECT FIELD）
cr11_mkobj(){ local db=$1 t=$2 out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || fail "  建表 $db.$t 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  out=$(sqt "show tables from $db;")
  printf '%s' "$out" | grep -q "$t" && pass "  建表成功：$db.$t" || fail "  场景无效：$db.$t 未建成"
  printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"; }
# 写一段 OBJECT 点：<db> <table> <dev> <base_ms> <n> <hex>
cr11_ins(){ local db=$1 t=$2 dev=$3 base=$4 n=$5 hex=$6 k kv="" out
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * 10 )),'$dev',$k,to_object(true,0,X'$hex')),"; done
  out=$(sqt "insert into $db.$t (time, dev, v, o) values ${kv%,};")
  printf '%s' "$out" | grep -q 'successfully' || fail "  写入 $db.$t dev=$dev 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  printf '%s\n' "$out" | grep -q 'successfully' && log "    已写入 $db.$t $dev：$n 点（ts 基准 $base，载荷 X'$hex'）"; }
# 某表的可见 OBJECT 行数
cr11_rows(){ local db=$1 t=$2; scalar "$(sqt "select count(o) from $db.$t;")"; }
# 轮询等某个时间段内的 object 真实文件数归零（异步 GC）；返回 0=归零 / 1=超时
cr11_wait_range_zero(){ local lo=$1 hi=$2 win=$3 label=$4 dl cur
  dl=$(( $(date +%s) + win )); cur=$(cr11_range_cnt "$lo" "$hi")
  while (( $(date +%s) < dl )); do
    cur=$(cr11_range_cnt "$lo" "$hi")
    log "    等 $label 的 object 清理：剩余=$cur（时间窗 $lo~$hi）"
    [ "${cur:-1}" -eq 0 ] && return 0
    sleep 5
  done
  echo "$cur"; return 1; }

# ============================================================================
log "--- 集群准备（CR-11：三类合并全关，避免合并插手；TTL 保持 INF ⇒ TTL 路径不删任何 object）---"
export TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_compaction_off
log "  生效值：seq=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) unseq=$(cmp_eff "${DN[0]}" enable_unseq_space_compaction) cross=$(cmp_eff "${DN[0]}" enable_cross_space_compaction)"

# ---------------------------------------------------------------------------
log "--- 阶段 0：造数据（两批 flush ⇒ 2 个 TsFile）+ 场景有效性 ---"
NOW=$(now_ms)
A_BASE=$(( NOW - 900000 ))                       # 批次 A（将被部分删除）
B_BASE=$(( A_BASE + HOLD_MS ))                   # 批次 B（保持）
A_LO=$(( A_BASE + 10 )); A_HI=$(( A_BASE + ROWS * 10 ))     # A 段实际时间戳范围
B_LO=$(( B_BASE + 10 )); B_HI=$(( B_BASE + ROWS * 10 ))
T_CUT=$(( A_HI + 1 ))                            # <= 该值恰好只删批次 A
C2_BASE=$(( B_BASE + HOLD_MS ))                  # 同库另一张表（t2）
C2_LO=$(( C2_BASE + 10 )); C2_HI=$(( C2_BASE + ROWS2 * 10 ))
CK_BASE=$(( C2_BASE + HOLD_MS ))                 # 隔离库（cro11b.tk）
CK_LO=$(( CK_BASE + 10 )); CK_HI=$(( CK_BASE + ROWS2 * 10 ))
log "  时间窗：A=[$A_LO,$A_HI] B=[$B_LO,$B_HI] t2=[$C2_LO,$C2_HI] tk=[$CK_LO,$CK_HI] T_CUT=$T_CUT"

cr11_mkobj "$DB" "$T1"
cr11_mkobj "$DB" "$T2"
cr11_mkobj "$DBK" "$TK"
G0=$(cr11_obj_all)
D=1
while [ "$D" -le "$DEVS" ]; do cr11_ins "$DB" "$T1" "d$D" "$A_BASE" "$ROWS" 61; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS" ]; do cr11_ins "$DB" "$T1" "d$D" "$B_BASE" "$ROWS" 62; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS2" ]; do cr11_ins "$DB" "$T2" "e$D" "$C2_BASE" "$ROWS2" 63; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS2" ]; do cr11_ins "$DBK" "$TK" "k$D" "$CK_BASE" "$ROWS2" 64; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
ensure_closed "$DB" 3 25 || warn "  $DB 有 DN 的 TsFile 未落盘"
ensure_closed "$DBK" 2 20 || warn "  $DBK 有 DN 的 TsFile 未落盘"

R1_WANT=$(( DEVS * ROWS * 2 ))
R2_WANT=$(( DEVS2 * ROWS2 ))
wait_scalar_table "select count(o) from $DB.$T1;" "$R1_WANT" 90 "  阶段 0：$DB.$T1 行数（$DEVS 设备 × 2 批 × $ROWS）"
wait_scalar_table "select count(o) from $DB.$T2;" "$R2_WANT" 60 "  阶段 0：$DB.$T2 行数"
wait_scalar_table "select count(o) from $DBK.$TK;" "$R2_WANT" 60 "  阶段 0：$DBK.$TK 行数"

G1=$(cr11_obj_stable "$STABLE_W")
OBJ_NEW=$(( G1 - G0 ))
if [ "${OBJ_NEW:-0}" -gt 0 ]; then
  pass "  场景有效性 H1：磁盘上确实生成了 object 真实文件 +$OBJ_NEW（全局 .bin 计数 $G0 → $G1）"
else
  fail "  场景无效 H1：未见 object 真实文件（+0）⇒ OBJECT 存储路径/DDL 与本环境不符，或未落盘（场景不可构造）"
fi
cb_A=$(cr11_range_cnt "$A_LO" "$A_HI"); cb_B=$(cr11_range_cnt "$B_LO" "$B_HI")
cb_2=$(cr11_range_cnt "$C2_LO" "$C2_HI"); cb_K=$(cr11_range_cnt "$CK_LO" "$CK_HI")
log "  基线（按 pointTime 时间段逐点计数 / 全局 $G1）：A=$cb_A B=$cb_B t2=$cb_2 tk=$cb_K"
POINTWISE=0
if [ "$cb_A" = "$(( DEVS * ROWS * 3 ))" ] && [ "$cb_B" = "$(( DEVS * ROWS * 3 ))" ] && [ "$cb_2" = "$(( DEVS2 * ROWS2 * 3 ))" ]; then
  POINTWISE=1
  pass "  场景有效性：object 文件与「点数 × 3 副本」1:1（A/B 各 $cb_A/$cb_B，t2=$cb_2）⇒ 逐时间段判据可用"
else
  warn "  W1：object 与点数非 1:1（期望 A/B=$(( DEVS * ROWS * 3 ))、t2=$(( DEVS2 * ROWS2 * 3 ))）⇒ 理论值判据降级，只判"相对基线的变化""
fi
DB_OBJ0=$(cr11_obj_db_all "$DB"); DBK_OBJ0=$(cr11_obj_db_all "$DBK")
log "  按 region 精确计数（信息性）：$DB=$DB_OBJ0 $DBK=$DBK_OBJ0"
RID=$(ttl_region_ids "${DN[0]}" "$DB" | tr '\n' ' ')
RIDK=$(ttl_region_ids "${DN[0]}" "$DBK" | tr '\n' ' ')
log "  region：$DB=[$RID] $DBK=[$RIDK]"
log "  表目录观测：$(cr11_region_ls "${DN[0]}" "$(printf '%s' "$RID" | awk '{print $1}')")"
DELGC0=$(cr11_del_gc_all); DELTTL0=$(cr11_del_ttl_all); FAIL0=$(cr11_fail_snapshot)
log "  删除日志基线：GC 路径=$DELGC0 TTL 路径=$DELTTL0；失败计数：$FAIL0"

# ---------------------------------------------------------------------------
log "--- 阶段 1（R-50 后半句 / R-47）：部分时间范围删除 ⇒ 该段 object 必须物理清理 ---"
OUT1=$(sqt "delete from $DB.$T1 where time <= $T_CUT;")
log "  DELETE 响应：$(printf '%s' "$OUT1" | tr '\n' ' ' | cut -c1-160)"
wait_scalar_table "select count(o) from $DB.$T1;" "$(( DEVS * ROWS ))" 120 "  阶段 1：被删段查不到（剩余批次 B：$(( DEVS * ROWS )) 行）"
if cr11_wait_range_zero "$A_LO" "$A_HI" "$OBJ_WIN" "阶段 1/A 段" >/dev/null; then
  pass "  阶段 1 H2：A 段 object 真实文件已物理清理（$cb_A → 0）"
else
  RA=$(cr11_range_cnt "$A_LO" "$A_HI")
  fail "  阶段 1 H2：A 段 object 真实文件未清理（基线 $cb_A → 残留 $RA，等 ${OBJ_WIN}s）⇒ 只做了逻辑删除？"
fi
ca_B=$(cr11_range_cnt "$B_LO" "$B_HI"); ca_2=$(cr11_range_cnt "$C2_LO" "$C2_HI"); ca_K=$(cr11_range_cnt "$CK_LO" "$CK_HI")
assert_eq "  阶段 1 H3：未删段（批次 B）object 完全不变" "$ca_B" "$cb_B"
assert_eq "  阶段 1 H3：同库另一张表 $T2 的 object 完全不变" "$ca_2" "$cb_2"
assert_eq "  阶段 1 H3：另一库 $DBK 的 object 完全不变" "$ca_K" "$cb_K"
DELGC1=$(cr11_del_gc_all); DELTTL1=$(cr11_del_ttl_all)
[ "${DELGC1:-0}" -gt "${DELGC0:-0}" ] && pass "  阶段 1：GC 路径（DataNodeObjectFileService）删除日志 +$(( DELGC1 - DELGC0 ))" \
  || warn "  W3：文件数已下降但 GC 路径删除日志无增量（$DELGC0→$DELGC1）——记录，不单独判缺陷"
assert_eq "  阶段 1：TTL 路径（CompactionUtils）删除计数恒为 0（本用例所有表 TTL=INF）" "$DELTTL1" "$DELTTL0"
log "  阶段 1 后全局 object 真实文件=$(cr11_obj_all)；按 region：$DB=$(cr11_obj_db_all "$DB") $DBK=$(cr11_obj_db_all "$DBK")"
if [ "$POINTWISE" != 1 ]; then
  log "  （W1 生效）逐段计数：A=$ca_A B=$ca_B t2=$ca_2 tk=$ca_K"
fi

# ---------------------------------------------------------------------------
log "--- 阶段 2（R-49/R-50 前半句）：整表删除（无 WHERE ⇒ isDroppingTable）⇒ 墓碑改名 + 异步 GC ---"
log "  删除前表目录观测：$(cr11_region_ls "${DN[0]}" "$(printf '%s' "$RID" | awk '{print $1}')")"
OUT2=$(sqt "delete from $DB.$T1;")
log "  DELETE FROM $DB.$T1 响应：$(printf '%s' "$OUT2" | tr '\n' ' ' | cut -c1-200)"
wait_scalar_table "select count(o) from $DB.$T1;" "0" 120 "  阶段 2：整表删除后查不到（行数 0）"
TOMB=0
dl=$(( $(date +%s) + OBJ_WIN ))
while (( $(date +%s) < dl )); do
  TOMB_NOW=0
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "find $DB_DIR/data -type d -name '.iotdb-objectgc' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    [ "${n:-0}" -gt 0 ] && TOMB_NOW=1
  done
  [ "$TOMB_NOW" = 1 ] && TOMB=1
  CUR_B=$(cr11_range_cnt "$B_LO" "$B_HI")
  log "    等整表 object 回收：B 段剩余=$CUR_B（基线 $cb_B）；墓碑目录已观测=$TOMB_NOW"
  [ "${CUR_B:-1}" -eq 0 ] && break
  sleep 5
done
if [ "${CUR_B:-1}" -eq 0 ]; then
  pass "  阶段 2 H4：整表删除后 B 段 object 真实文件全部物理清理（$cb_B → 0）"
else
  fail "  阶段 2 H4/H7：整表删除后 B 段 object 仍残留 $CUR_B（基线 $cb_B，等 ${OBJ_WIN}s）⇒ 逻辑删除已生效但物理文件未清理（R-47 失败模式）"
  log "    残留文件清单（${DN[0]}）：$(sshx "${DN[0]}" "find $DB_DIR/data -path '*object*' -name '*.bin*' -printf '%p\n' 2>/dev/null | head -20" | tr '\n' ' ' | cut -c1-600)"
fi
[ "$TOMB" = 1 ] && pass "  阶段 2：观测到墓碑目录 .iotdb-objectgc（renameTableDirForDrop 的直接证据）" \
                 || warn "  W2：轮询窗口内未观测到墓碑目录（GC 可能已完成，或本构建走其它路径）——记录，不判缺陷"
ca2_2=$(cr11_range_cnt "$C2_LO" "$C2_HI"); ca2_K=$(cr11_range_cnt "$CK_LO" "$CK_HI"); ca2_A=$(cr11_range_cnt "$A_LO" "$A_HI")
assert_eq "  阶段 2 H3：同库另一张表 $T2 的 object 完全不变" "$ca2_2" "$cb_2"
assert_eq "  阶段 2 H3：另一库 $DBK 的 object 完全不变" "$ca2_K" "$cb_K"
log "  阶段 2 后表目录观测：$(cr11_region_ls "${DN[0]}" "$(printf '%s' "$RID" | awk '{print $1}')")（A 段残留=$ca2_A）"

# ---------------------------------------------------------------------------
log "--- 阶段 3（R-51）：DROP DATABASE ⇒ 该 region 的 object 目录被清理 ---"
DB_OBJ_BEFORE=$(cr11_obj_db_all "$DB")
OUT3=$(sqt "drop database $DB;")
log "  DROP DATABASE 响应：$(printf '%s' "$OUT3" | tr '\n' ' ' | cut -c1-200)"
printf '%s' "$OUT3" | grep -q 'successfully' && pass "  阶段 3：DROP DATABASE $DB 成功" \
  || fail "  阶段 3：DROP DATABASE $DB 未返回 successfully：$(printf '%s' "$OUT3" | tr '\n' ' ' | cut -c1-200)"
dl=$(( $(date +%s) + OBJ_WIN )); DB_OBJ_NOW=$DB_OBJ_BEFORE
while (( $(date +%s) < dl )); do
  DB_OBJ_NOW=$(cr11_obj_db_all "$DB")
  log "    等整库 object 清理：$DB 按 region 计数=$DB_OBJ_NOW（删除前 $DB_OBJ_BEFORE）"
  [ "${DB_OBJ_NOW:-1}" -eq 0 ] && break
  sleep 5
done
if [ "${DB_OBJ_NOW:-1}" -eq 0 ]; then
  pass "  阶段 3 H5：DROP DATABASE 后该 region 的 object 真实文件全部清理（$DB_OBJ_BEFORE → 0）"
else
  fail "  阶段 3 H5：DROP DATABASE 后 $DB 仍有 $DB_OBJ_NOW 个 object 真实文件（等 ${OBJ_WIN}s）"
  for h in "${DN[@]}"; do
    log "    $h 残留：$(sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' -printf '%p\n' 2>/dev/null | head -10" | tr '\n' ' ' | cut -c1-400)"
  done
fi
ck_K=$(cr11_range_cnt "$CK_LO" "$CK_HI"); DBK_OBJ1=$(cr11_obj_db_all "$DBK")
assert_eq "  阶段 3 H3：另一库 $DBK 的 object 完全不变（逐点计数）" "$ck_K" "$cb_K"
assert_eq "  阶段 3 H3：另一库 $DBK 的 object 完全不变（按 region 计数）" "$DBK_OBJ1" "$DBK_OBJ0"
wait_scalar_table "select count(o) from $DBK.$TK;" "$R2_WANT" 60 "  阶段 3：隔离库 $DBK.$TK 数据仍可查"

# ---------------------------------------------------------------------------
log "--- 阶段 4：异常日志硬判据（H6）+ 证据汇总 ---"
FAIL1=$(cr11_fail_snapshot)
log "  失败计数：基线 $FAIL0 / 终态 $FAIL1"
f_get(){ printf '%s' "$1" | tr ' ' '\n' | grep -F "$2" ; }
for h in "${DN[@]}"; do
  a=$(f_get "$FAIL0" "${h##*.}:"); b=$(f_get "$FAIL1" "${h##*.}:")
  log "    $h：$a → $b"
done
for kind in remove gc list; do
  tot0=0; tot1=0
  for h in "${DN[@]}"; do
    v0=$(printf '%s' "$FAIL0" | tr ' ' '\n' | grep -F "${h##*.}:" | tr ',' '\n' | grep "^$kind=" | cut -d= -f2)
    v1=$(printf '%s' "$FAIL1" | tr ' ' '\n' | grep -F "${h##*.}:" | tr ',' '\n' | grep "^$kind=" | cut -d= -f2)
    tot0=$(( tot0 + ${v0:-0} )); tot1=$(( tot1 + ${v1:-0} ))
  done
  assert_eq "  H6：$kind 类删除失败计数不得增加（全部 DN 合计）" "$tot1" "$tot0"
done
DELGC2=$(cr11_del_gc_all); DELTTL2=$(cr11_del_ttl_all)
log "  删除日志终态：GC 路径=$DELGC2（基线 $DELGC0）TTL 路径=$DELTTL2（基线 $DELTTL0）"
assert_eq "  全程：TTL 路径（CompactionUtils）删除计数恒为 0" "$DELTTL2" "$DELTTL0"
for h in "${DN[@]}"; do
  log "  $h object 删除日志尾部：$(sshx "$h" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | tail -2" | tr '\n' ' ' | cut -c1-240)"
done
log "  隔离库终态 object（按 region）：$(cr11_obj_db_all "$DBK")"

log "--- 收尾三件套（基准用存活的隔离库 $DBK.$TK）---"
post_checks "select o from $DBK.$TK order by time;" table
cmp_case_finish "" table ""
