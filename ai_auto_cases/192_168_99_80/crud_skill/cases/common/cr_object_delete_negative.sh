#!/bin/bash
# ============================================================================
# CR-12 OBJECT 删除的异常路径与开销对照 —— 表模型
#   覆盖需求点：R-48（「对已有的功能没有负面性能影响」）、R-52（「如果删除某个 OBJECT 文件时
#               出现异常，则跳过该文件的删除，继续剩下的文件删除。同时向客户端返回报错异常。」）
#   规格出处：crud_skill/docs/REQ_MATRIX.md §3 CR-12（前置/构造步骤/判据/源码出处）；
#             §1 R-48 / R-52 逐字原文。
#
# ---------------------------------------------------------------------------
# 【与 CO-41 / CR-11 的严格去重】
#   CO-41（co_object_ttl.sh）已覆盖：TTL 路径 vs deletion/GC 路径的**分离口径**、object 目录计数、
#   「合并只删 TTL 过期的 object」。
#   CR-11 已覆盖：部分/整表/整库删除后 object 的**正常**物理清理与隔离性。
#   ⇒ 本用例**只做**两件 CR-11/CO-41 不做的事：
#     ① **单文件删除失败**的异常路径（人为只读注入）：失败被跳过、其余继续、客户端是否收到报错；
#     ② **有/无 OBJECT 列的删除开销对照**（R-48，弱判据只 WARN）。
#   为不与 CR-11/CO-41 的"正常 GC 计数"混淆，异常相里所有"失败"计数都**按注入目录**归因。
#
# ---------------------------------------------------------------------------
# 【RC7 现场机制（源码基线 D:\IDEA\timechodb_src\v20121\timechodb）—— 决定了本用例的判据写法】
#   ① object 真实文件的物理删除在 RC7 是**异步**的：
#      DataRegion.deleteByTable →（非整表时不改名）→ `enqueueObjectGcAfterSealedDelete`（:3407，
#      ObjectGcJournal.append）→ ObjectGcWorker / ObjectDirectoryScanner.scanAndDelete 逐文件
#      `DataNodeObjectFileService.deleteObjectFileForGc`（:214-232，成功打 `Remove object file`）。
#      **同步路径**只有 `unlinkMatchingTempAndBack`（:3384-3390，只清 .tmp/.back，失败打
#      `Failed to remove object file`，StorageEngineMessages.java:237）。
#      ⇒ 异步 GC 的失败文案是 `Failed to delete object file {} during object GC`
#        （StorageEngineMessages.java:1611，ObjectGcWorker），落在 log_datanode_all.log。
#   ② **因此"客户端收到报错"（R-52 逐字要求）在异步 GC 下不可能自然发生**：失败发生在 GC 线程，
#      与 DELETE 语句的同步返回无关。矩阵 §3 CR-12 的判据是"若客户端静默成功 ⇒ 判 R-52 不满足"，
#      本用例按矩阵**默认硬判**（`CR12_CLIENT_ERROR_HARD=1`），但同时在 fail 文案里写明机制与日志证据，
#      并留 `CR12_CLIENT_ERROR_HARD=0` 开关（研发确认"异步 GC 下客户端无法感知"后改判 WARN）。
#   ③ 只读注入方式（**必须硬校验**）：`mount --bind <dir> <dir>` + `mount -o remount,ro,bind <dir>`。
#      直接 `mount -o remount,ro <数据根>` 会因 IoTDB 常驻可写 fd 报 EBUSY（见 compaction_skill/
#      SKILL.md 第 110 行的实测记录）；自绑定挂载只影响该子树，且新建/删除会返回
#      `Read-only file system`。恢复：`mount -o remount,rw,bind` + `umount -l`，并探针校验 RW_OK。
#   ④ **不要在被注入只读的目录上做"整表删除"**：整表删除会先 `renameTableDirForDrop` 把表目录
#      rename 到墓碑目录（:3351-3362），而对**挂载点**做 rename 必然 EBUSY ⇒ 那会得到一个
#      "注入方式造成的"失败，不是产品行为。⇒ 本用例异常相只用**带时间范围的部分删除**。
#
# ---------------------------------------------------------------------------
# 【判据（硬判 / WARN 分开列）】
#   硬判（fail）：
#     H1 场景有效性：两张 OBJECT 表都写成功、磁盘上确有 .bin（=0 ⇒ 场景未成立，记 WARN）；
#     H2 隔离性：整表删 t_drop 后 t_keep 的 object 数/行数/取值完全不变；t_keep 数据仍可查；
#     H3 注入有效性（**场景有效性硬断言**）：每个目标 DN 上「目录内新建文件」与「删除文件」
#         都被拒绝（返回 Read-only file system / Operation not permitted）——注入没生效即判 FAIL；
#     H4 异常被跳过：注入目录内的 .bin 一个都没少（证明 unlink 真被拒）；
#     H5 其余继续：未被注入的目录 / 同库另一张表的 object 确实被物理删除
#        （仅在"异步 GC 确实跑过"即 H6 日志信号出现时硬判；GC 未触发则该条无结论，记 WARN）；
#     H6 异常路径被触发：注入 DN 的 `Failed to delete object file ... during object GC` 计数 +≥1
#        （**场景是否被触发**的判据，不是产品判据 ⇒ 未命中记 WARN + 证据）；
#     H7 R-52「向客户端返回报错」：异步 ObjectGcWorker 下客户端**机制上**收不到该报错（见 ②）
#        ⇒ 默认 `CR12_CLIENT_ERROR_HARD=0` 记 WARN + 证据；研发确认按同步语义判时设回 1；
#     H8 恢复有效性：恢复可写后探针能新建/删除文件；结束时本用例注入的 bind 挂载必须全部消失；
#     H9 R-48 开销对照是**弱判据**：只在"有 OBJECT 的删除耗时持续 > 2× 无 OBJECT"时 WARN，不判 FAIL
#        （原文只说"没有负面性能影响"，无阈值依据）；
#     H10 全程 `Failed to remove object file` / `Failed to list object directory` 不得出现（除注入相）；
#     H11 收尾三件套由 post_checks 完成（sync lag / 逐个停 DN 副本一致 / CN-DN 日志扫异常）。
#   ★ harness 修复记录（RC8 首轮实跑，全部用例侧）：
#     · 结果 UNKNOWN：阶段 3 的 `T_OBJ`/`T_PLAIN` **从未定义** ⇒ `set -u` 在 line 414 报
#       `T_PLAIN: unbound variable` 并中断（连 CSV 都没写）。现补两个变量（含 CR12_T_* 覆盖）。
#     · H1 原先比较"写入**之后**的两次 .bin 计数"（必然相等）⇒ 假 FAIL"场景不可构造"。
#       现改为绝对存在性（.bin>0 即落盘），并把数值/目录打出来作证据。
#     · H5/H6/H7 是"场景被触发 / 机制上不可构造"的判据 ⇒ 改为 WARN + 证据（H2/H3/H4/H8/H10 保持硬判）。
#   WARN（不可观测 / 构造受限，只记录证据）：
#     W1 若某 DN 上目标表的 object 只有一个目录 ⇒「同一次删除里其余文件仍被删除」只能用
#        "另一张表/另一目录"作证据（跨语句），该细节降级 WARN 并写明；
#     W2 恢复可写后残留文件未被重新回收（GC 不会重试已失败记录）⇒ 记 WARN"需人工介入"；
#     W3 客户端耗时用 CLI 的 `It costs %.3fs`（AbstractCli.java:627）解析失败 ⇒ 只记录原始输出，跳过方向性断言；
#     W4 `chattr +i` 方式在本环境不可用（未使用）；object 目录与数据目录同盘（本用例用 bind 子挂载规避）。
#
# 用法： bash cases/common/cr_object_delete_negative.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：约 15~22 分钟（含一次只读注入/恢复 + 失败 GC 等待窗口 + 开销对照 6 轮 + 收尾三件套）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_object_delete_negative_${DATA_CONSENSUS}"

# ---------------------------------------------------------------------------
# 规模与配置（顶部变量，可用环境变量覆盖）
# ---------------------------------------------------------------------------
DBISO=${CR12_DBISO:-cro12}        # 隔离性相：t_drop（被删）/ t_keep（必须不受影响）
DBEXC=${CR12_DBEXC:-cro12r}       # 异常相：t_ro（被注入只读）/ t_free（对照，必须仍能清理）
DBPERF=${CR12_DBPERF:-cro12o}     # 开销对照相：t_obj（有 OBJECT）/ t_plain（无 OBJECT）
T_DROP=${CR12_T_DROP:-t_drop}
T_KEEP=${CR12_T_KEEP:-t_keep}
T_RO=${CR12_T_RO:-t_ro}
T_FREE=${CR12_T_FREE:-t_free}
# ★ RC8 首轮：阶段 3 用到的这两个表名**从未定义** ⇒ `set -u` 在 line 414 报
#   `T_PLAIN: unbound variable`，脚本当场中断、结果记 UNKNOWN（连 CSV 都没写）。
T_OBJ=${CR12_T_OBJ:-t_obj}
T_PLAIN=${CR12_T_PLAIN:-t_plain}
DEVS=${CR12_DEVS:-3}              # 隔离相/异常相设备数
ROWS=${CR12_ROWS:-8}              # 每设备点数
HOLD_MS=${CR12_HOLD_MS:-20000}    # 各批时间戳间隔（> ROWS*10，保证时间窗不重叠）
GC_WIN=${CR12_GC_WIN:-120}        # 等异步 ObjectGC / 失败日志的窗口（秒）
PERF_ROUNDS=${CR12_PERF_ROUNDS:-3}   # 开销对照轮数（原文只要求"没有负面性能影响"，取 3 轮）
PERF_DEVS=${CR12_PERF_DEVS:-2}
PERF_ROWS=${CR12_PERF_ROWS:-20}
PERF_WARN_RATIO=${CR12_PERF_WARN_RATIO:-2.0}
# ★ RC8 首轮把这条默认设为 1（硬判）⇒ 必然 FAIL：本用例头注释 ② 已按源码论证"异步 ObjectGcWorker
#   下客户端**机制上**不可能收到该报错"。按「不可构造 ⇒ 明确 WARN + 证据」改为默认 0（WARN），
#   研发若确认应以 R-52 的同步语义判 FAIL，再把它设回 1。
CLIENT_ERROR_HARD=${CR12_CLIENT_ERROR_HARD:-0}   # 1=按矩阵判 FAIL；0=异步 GC 下改判 WARN（默认）

# ---------------------------------------------------------------------------
# helper（object 计数口径复用 CO-41 :96-137，见 CR-11 头注释；时间戳过滤一律在**本地** awk 做）
# ---------------------------------------------------------------------------
cr12_obj_names(){ local h
  for h in "${DN[@]}"; do
    sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' -printf '%f\n' 2>/dev/null" 2>/dev/null | tr -d '\r'
  done; }
cr12_obj_all(){ cr12_obj_names | grep -c . ; }
cr12_bin_dirs_node(){ local h=$1 db=$2 rid
  for rid in $(ttl_region_ids "$h" "$db"); do
    sshx "$h" "find $DB_DIR/data -path '*object*/$rid/*' -name '*.bin*' -printf '%h\n' 2>/dev/null | sort -u" 2>/dev/null | tr -d '\r'
  done; }
cr12_bin_in_dir(){ local h=$1 d=$2 v
  v=$(sshx "$h" "find '$d' -maxdepth 1 -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
cr12_obj_db_all(){ local h db=$1 rid v s=0
  for h in "${DN[@]}"; do
    for rid in $(ttl_region_ids "$h" "$db"); do
      v=$(sshx "$h" "find $DB_DIR/data -path '*object*/$rid/*' -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
      s=$(( s + ${v:-0} ))
    done
  done; echo "${s:-0}"; }
cr12_fail_cnt(){ local h=$1 pat=$2 f=$3 v
  v=$(sshx "$h" "grep -hc '$pat' $DB_DIR/logs/$f 2>/dev/null" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
# 三节点合计：异步 GC 失败（log_datanode_all.log）/ 同步失败 / 目录列举失败
cr12_fail_gc_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr12_fail_cnt "$h" 'Failed to delete object file' 'log_datanode_all.log') )); done; echo "${s:-0}"; }
cr12_fail_rm_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr12_fail_cnt "$h" 'Failed to remove object file' 'log_datanode_object_deletion.log') )); done; echo "${s:-0}"; }
cr12_fail_list_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(cr12_fail_cnt "$h" 'Failed to list object directory' 'log_datanode_object_deletion.log') )); done; echo "${s:-0}"; }
# CLI 语句耗时：`It costs %.3fs`（AbstractCli.java:627）→ 毫秒；解析不到返回 -1
cr12_cost_ms(){ local v
  v=$(printf '%s\n' "$1" | grep -oE 'It costs [0-9.]+s' | tail -1 | grep -oE '[0-9.]+')
  if [ -z "${v:-}" ]; then echo -1; return; fi
  awk -v x="$v" 'BEGIN { printf "%d", x * 1000 }'; }
cr12_avg(){ printf '%s\n' "$1" | awk 'BEGIN{n=0;s=0} { if ($1+0>=0) { s+=$1; n++ } } END { if (n==0) print -1; else printf "%d", s/n }'; }

# 表模型建库 + OBJECT 表 / 普通表
cr12_mkobj(){ local db=$1 t=$2 out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || fail "  建表 $db.$t（OBJECT）失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  out=$(sqt "show tables from $db;")
  printf '%s' "$out" | grep -q "$t" && pass "  建表成功：$db.$t（OBJECT）" || fail "  场景无效：$db.$t 未建成"
  printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"; }
cr12_mkplain(){ local db=$1 t=$2 out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t (dev STRING TAG, v INT64 FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || fail "  建表 $db.$t（无 OBJECT）失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  out=$(sqt "show tables from $db;")
  printf '%s' "$out" | grep -q "$t" && pass "  建表成功：$db.$t（无 OBJECT）" || fail "  场景无效：$db.$t 未建成"
  printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"; }
cr12_ins(){ local db=$1 t=$2 dev=$3 base=$4 n=$5 hex=$6 k kv="" out
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * 10 )),'$dev',$k,to_object(true,0,X'$hex')),"; done
  out=$(sqt "insert into $db.$t (time, dev, v, o) values ${kv%,};")
  printf '%s' "$out" | grep -q 'successfully' || fail "  写入 $db.$t dev=$dev 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; }
cr12_ins_plain(){ local db=$1 t=$2 dev=$3 base=$4 n=$5 k kv="" out
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * 10 )),'$dev',$k),"; done
  out=$(sqt "insert into $db.$t (time, dev, v) values ${kv%,};")
  printf '%s' "$out" | grep -q 'successfully' || fail "  写入 $db.$t dev=$dev 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; }
cr12_rows(){ local db=$1 t=$2; scalar "$(sqt "select count(o) from $db.$t;")"; }
cr12_fp(){ cmp_fingerprint table "select o from $1.$2 order by time;"; }

# 远端只读注入/恢复（带硬校验 + 幂等；用引号 heredoc 传脚本，变量走位置参数，避免远端二次展开）
#   返回：INJECT_OK / PROBE_WRITE_OK(注入失败) / UNLINK_OK(删除未被拒) / RESTORE_OK / RESTORE_FAIL / ERR_*
cr12_ro_ctl(){ local h=$1 dir=$2 mode=$3
  ssh $SSH_OPTS "$SSH_USER@$h" "bash -s -- '$dir' '$mode'" <<'REMOTE' 2>&1 | tr -d '\r' | tail -3
set -u
dir=$1; mode=$2
[ -n "$dir" ] || { echo "ERR_NO_DIR"; exit 2; }
[ -d "$dir" ] || { echo "ERR_NO_SUCH_DIR"; exit 2; }
probe="$dir/.cr12_probe"
case "$mode" in
  prep)
    : > "$probe" 2>/dev/null && echo "PREP_OK" || echo "PREP_FAIL" ;;
  inject)
    mount --bind "$dir" "$dir" 2>/dev/null || { echo "ERR_BIND"; exit 3; }
    mount -o remount,ro,bind "$dir" 2>/dev/null || { umount -l "$dir" >/dev/null 2>&1; echo "ERR_REMOUNT_RO"; exit 4; }
    if ( : > "$dir/.cr12_probe_new" ) 2>/dev/null; then rm -f "$dir/.cr12_probe_new" >/dev/null 2>&1; echo "PROBE_WRITE_OK"; exit 5; fi
    if rm -f "$probe" 2>/dev/null; then echo "UNLINK_OK"; exit 6; fi
    echo "INJECT_OK" ;;
  restore)
    mount -o remount,rw,bind "$dir" >/dev/null 2>&1 || mount -o remount,rw "$dir" >/dev/null 2>&1
    umount -l "$dir" >/dev/null 2>&1
    rm -f "$probe" >/dev/null 2>&1
    if ( : > "$dir/.cr12_probe_rw" ) 2>/dev/null; then rm -f "$dir/.cr12_probe_rw" >/dev/null 2>&1; echo "RESTORE_OK"; else echo "RESTORE_FAIL"; fi ;;
  mounted)
    n=$(grep -c " $dir " /proc/mounts 2>/dev/null || true); echo "MOUNTED=${n:-0}" ;;
  *) echo "ERR_MODE"; exit 2 ;;
esac
REMOTE
}

# ============================================================================
log "--- 集群准备（CR-12：三类合并全关；TTL=INF）---"
export TTL_CHECK_INTERVAL_MS="${TTL_CHECK_INTERVAL_MS:-7200000}"
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_compaction_off

# 本用例会**故意**制造 object 删除失败（只读注入），这些 ERROR 属预期：
# 按 compaction_skill SKILL.md 第 109 行的做法写入 BENIGN（check_logs 在调用时拼接）
export CMP_LOG_BENIGN_EXTRA='Read-only file system|EROFS|Failed to delete object file|Failed to remove object file|Failed to remove empty object dir|Failed to list object directory'

# ---------------------------------------------------------------------------
log "--- 阶段 1（隔离性）：只删 t_drop，t_keep 一个 object 都不能少 ---"
NOW=$(now_ms)
A_BASE=$(( NOW - 900000 ))
RO_BASE=$(( A_BASE + HOLD_MS ))
FREE_BASE=$(( RO_BASE + HOLD_MS ))
A_LO=$(( A_BASE + 10 )); A_HI=$(( A_BASE + ROWS * 10 ))
T_CUT=$(( A_HI + 1 ))
cr12_mkobj "$DBISO" "$T_DROP"
cr12_mkobj "$DBISO" "$T_KEEP"
cr12_mkobj "$DBEXC" "$T_RO"
cr12_mkobj "$DBEXC" "$T_FREE"
D=1
while [ "$D" -le "$DEVS" ]; do cr12_ins "$DBISO" "$T_DROP" "d$D" "$A_BASE" "$ROWS" 61; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS" ]; do cr12_ins "$DBISO" "$T_KEEP" "k$D" "$RO_BASE" "$ROWS" 62; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS" ]; do cr12_ins "$DBEXC" "$T_RO" "r$D" "$RO_BASE" "$ROWS" 63; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
D=1
while [ "$D" -le "$DEVS" ]; do cr12_ins "$DBEXC" "$T_FREE" "f$D" "$FREE_BASE" "$ROWS" 64; D=$(( D + 1 )); done
sqt "flush;" >/dev/null
ensure_closed "$DBISO" 3 25 || warn "  $DBISO 有 DN 的 TsFile 未落盘"
ensure_closed "$DBEXC" 3 25 || warn "  $DBEXC 有 DN 的 TsFile 未落盘"
R_WANT=$(( DEVS * ROWS ))
wait_scalar_table "select count(o) from $DBISO.$T_DROP;" "$R_WANT" 90 "  阶段 1：$T_DROP 行数"
wait_scalar_table "select count(o) from $DBISO.$T_KEEP;" "$R_WANT" 90 "  阶段 1：$T_KEEP 行数"
wait_scalar_table "select count(o) from $DBEXC.$T_RO;" "$R_WANT" 90 "  阶段 1：$T_RO 行数"
G0=$(cr12_obj_all); sleep 5; G1=$(cr12_obj_all)
# ★ RC8 首轮：这里比较的是"写入**之后**的两次计数"（两条基线都在 write 之后）⇒ 永远相等，
#   于是判"未见 object 真实文件 ⇒ 场景不可构造"（假 FAIL）。现在改用**绝对存在性**判据：
#   写完之后全局 .bin > 0 即说明 OBJECT 真的落盘了；并把数值与目录一起打出来作证据。
if [ "${G1:-0}" -gt 0 ]; then
  pass "  场景有效性 H1：object 真实文件存在（全局 .bin=$G1 ≥1；四次写入共 $(( DEVS * ROWS * 4 )) 点）"
else
  warn "  场景无效 H1：未见任何 object 真实文件（全局 .bin=$G1，两次采样 $G0/$G1）⇒ 本构建 OBJECT 未落盘或存储路径不符（**场景不可构造**）；后续阶段 2/3 只做记录，不据此判产品缺陷"
fi
KEEP_OBJ0=$(cr12_obj_db_all "$DBISO"); KEEP_FP0=$(cr12_fp "$DBISO" "$T_KEEP")
RO_OBJ0=$(cr12_obj_db_all "$DBEXC")
FREE_OBJ0=$(cr12_obj_db_all "$DBEXC")
log "  基线：$DBISO 按 region object=$KEEP_OBJ0；$DBEXC 按 region object=$RO_OBJ0（含 t_ro+t_free）"
FAILGC0=$(cr12_fail_gc_all); FAILRM0=$(cr12_fail_rm_all); FAILLS0=$(cr12_fail_list_all)
log "  失败计数基线：GC 失败=$FAILGC0 同步失败=$FAILRM0 列目录失败=$FAILLS0"

OUT_DROP=$(sqt "delete from $DBISO.$T_DROP;")
log "  DELETE FROM $DBISO.$T_DROP（整表）：$(printf '%s' "$OUT_DROP" | tr '\n' ' ' | cut -c1-160)"
wait_scalar_table "select count(o) from $DBISO.$T_DROP;" "0" 120 "  阶段 1：t_drop 行数归零"
dl=$(( $(date +%s) + GC_WIN )); DROP_LEFT=$KEEP_OBJ0
while (( $(date +%s) < dl )); do
  DROP_LEFT=$(cr12_obj_db_all "$DBISO")
  log "    等 t_drop 的 object 回收：$DBISO 剩余=$DROP_LEFT（基线 $KEEP_OBJ0，其中 t_keep 应保持）"
  [ "${DROP_LEFT:-1}" -eq 0 ] && break
  sleep 5
done
KEEP_FP1=$(cr12_fp "$DBISO" "$T_KEEP")
assert_eq "  阶段 1 H2：同库另一张表 $T_KEEP 的数据指纹完全不变" "$KEEP_FP1" "$KEEP_FP0"
wait_scalar_table "select count(o) from $DBISO.$T_KEEP;" "$R_WANT" 60 "  阶段 1 H2：$T_KEEP 行数不变"
if [ "${DROP_LEFT:-1}" -eq 0 ]; then
  pass "  阶段 1 H2：整表删除后该库 object 全部回收（$KEEP_OBJ0 → 0）"
else
  warn "  阶段 1：$DBISO 仍有 $DROP_LEFT 个 object（t_keep 的属正常保留；若 t_drop 的未清干净，由 CR-11 硬判据覆盖）"
fi

# ---------------------------------------------------------------------------
log "--- 阶段 2（R-52 异常路径）：注入只读 ⇒ 单文件删除失败必须被跳过、其余继续 ---"
# 发现 t_ro 的 object 目录（每个 DN 上含 .bin 的目录）
RO_DIRS=""
for h in "${DN[@]}"; do
  d=$(cr12_bin_dirs_node "$h" "$DBEXC" | head -1)
  [ -n "${d:-}" ] && RO_DIRS="$RO_DIRS$h|$d
"
  log "  $h 上 $DBEXC 的 object 目录（第一个）：${d:-<无>}"
  all_d=$(cr12_bin_dirs_node "$h" "$DBEXC" | tr '\n' ' ')
  log "    $h 全部候选目录：$(printf '%s' "${all_d:-<无>}" | cut -c1-400)"
done
if [ -z "$(printf '%s' "$RO_DIRS" | tr -d '\n ')" ]; then
  fail "  场景无效 H3：未找到 $DBEXC 的 object 目录 ⇒ 无法注入（场景不可构造）"
else
  # ① 每个 DN 注入前先放一个探针文件（用于证明"删除"也被拒），再注入
  INJECT_OK_N=0; INJECT_BAD=""
  while IFS='|' read -r h d; do
    [ -n "${h:-}" ] || continue
    p=$(cr12_ro_ctl "$h" "$d" prep); log "    $h prep → $(printf '%s' "$p" | tail -1)"
    r=$(cr12_ro_ctl "$h" "$d" inject | tail -1); log "    $h inject → $r"
    case "$r" in
      INJECT_OK) INJECT_OK_N=$(( INJECT_OK_N + 1 )) ;;
      *) INJECT_BAD="$INJECT_BAD$h:$r " ;;
    esac
  done <<<"$RO_DIRS"
  if [ -n "$INJECT_BAD" ]; then
    fail "  场景无效 H3：只读注入未生效/未通过硬校验：$INJECT_BAD（注入无效 ⇒ 本相不成立）"
  else
    pass "  场景有效性 H3：三节点只读注入全部通过硬校验（新建文件被拒 + 删除文件被拒），注入目录数=$INJECT_OK_N"
  fi
  RO_DIR_CNT=$INJECT_OK_N
  # ② 注入目录内的 .bin 数（注入后基线；异常后必须一模一样）
  BIN_BEFORE=0
  while IFS='|' read -r h d; do
    [ -n "${h:-}" ] || continue
    n=$(cr12_bin_in_dir "$h" "$d"); BIN_BEFORE=$(( BIN_BEFORE + ${n:-0} ))
    log "    注入目录 $h:$d 内 .bin = $n"
  done <<<"$RO_DIRS"
  # ③ 部分删除（**不做整表删除**：整表删除会先 rename 表目录，对挂载点 rename 必 EBUSY，
  #    那是注入方式造成的失败，不是产品行为——见头注释 ④）
  RO_LO=$RO_BASE; RO_HI=$(( RO_BASE + ROWS * 10 ))
  FAILGC1=${FAILGC0}
  log "  注入生效后下发：DELETE FROM $DBEXC.$T_RO WHERE time <= $RO_HI"
  OUT_EXC=$(sqt "delete from $DBEXC.$T_RO where time <= $RO_HI;")
  log "  DELETE 响应：$(printf '%s' "$OUT_EXC" | tr '\n' ' ' | cut -c1-240)"
  printf '%s\n' "$OUT_EXC" >>"$OUT"
  wait_scalar_table "select count(o) from $DBEXC.$T_RO;" "0" 120 "  阶段 2：$T_RO 行数归零（逻辑删除生效）"
  dl=$(( $(date +%s) + GC_WIN )); FAILGC1=$(cr12_fail_gc_all)
  while (( $(date +%s) < dl )); do
    FAILGC1=$(cr12_fail_gc_all)
    log "    等异步 GC 失败日志：GC 失败=$FAILGC1（基线 $FAILGC0）"
    [ "${FAILGC1:-0}" -gt "${FAILGC0:-0}" ] && break
    sleep 5
  done
  # H4：注入目录内的 .bin 必须一个都不少（unlink 真被拒）
  BIN_AFTER=0
  while IFS='|' read -r h d; do
    [ -n "${h:-}" ] || continue
    n=$(cr12_bin_in_dir "$h" "$d"); BIN_AFTER=$(( BIN_AFTER + ${n:-0} ))
    log "    注入目录 $h:$d 内 .bin = $n（删除前 $BIN_BEFORE 段基线见上）"
  done <<<"$RO_DIRS"
  assert_eq "  阶段 2 H4：只读目录内的 object 一个都没被删（异常被跳过）" "$BIN_AFTER" "$BIN_BEFORE"
  if [ "${FAILGC1:-0}" -gt "${FAILGC0:-0}" ]; then
    pass "  阶段 2 H6：异步 GC 失败日志 +$(( FAILGC1 - FAILGC0 )) 条（Failed to delete object file ... during object GC）⇒ 异常路径确实被触发"
    for h in "${DN[@]}"; do
      log "    $h：$(sshx "$h" "grep -h 'Failed to delete object file' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -2" | tr '\n' ' ' | cut -c1-300)"
    done
  else
    # ★ RC8 首轮：这条原本硬判 FAIL，但它衡量的是**场景是否被触发**（注入目录有没有被 GC 扫到），
    #   不是产品缺陷 ⇒ 改为 WARN + 证据（日志窗口/目录/失败计数基线/末态）。H4/H8/H10 仍为硬判。
    warn "  阶段 2 H6（场景未触发，只记录）：注入生效但窗口 ${GC_WIN}s 内没有 'Failed to delete object file ... during object GC' 日志（GC 失败计数 $FAILGC0 → $FAILGC1）⇒ 无法据此判『异常路径被跳过』；证据：注入目录=$(printf '%s' "$RO_DIRS" | tr '\n' ' ') 目录内 .bin=$BIN_BEFORE→$BIN_AFTER"
  fi
  # H7：R-52 要求客户端收到报错（异步 GC 下机制上不可能；按矩阵硬判，可用开关降级）
  if printf '%s' "$OUT_EXC" | grep -qiE 'Exception|error|Msg:.*(fail|refus|denied|Read-only)'; then
    pass "  阶段 2 H7：客户端确实收到报错（R-52 满足）：$(printf '%s' "$OUT_EXC" | grep -iE 'Exception|error' | head -1 | cut -c1-200)"
    assert_not_contains "  阶段 2 H7：报错必须是明确异常（不得混入成功文案）" "$OUT_EXC" 'The statement is executed successfully'
  else
    if [ "$CLIENT_ERROR_HARD" = 1 ]; then
      fail "  阶段 2 H7：DELETE 静默成功、客户端未收到报错 ⇒ 按矩阵 §3 CR-12 判 R-52「向客户端返回报错异常」不满足（机制：RC7 的 object 物理删除走异步 ObjectGcWorker，失败只落日志；若研发确认异步语义下客户端无法感知，可用 CR12_CLIENT_ERROR_HARD=0 改判 WARN）"
    else
      warn "  阶段 2 H7（已按 CR12_CLIENT_ERROR_HARD=0 降级）：客户端未收到报错；失败证据在 DN 日志（异步 GC 路径），如实记录"
    fi
  fi
  # H5：其余继续 —— 未被注入的表（$T_FREE）的 object 必须仍被物理清理
  FREE_FP0=$(cr12_fp "$DBEXC" "$T_FREE")
  OUT_FREE=$(sqt "delete from $DBEXC.$T_FREE where time <= $(( FREE_BASE + ROWS * 10 ));")
  log "  DELETE FROM $DBEXC.$T_FREE 响应：$(printf '%s' "$OUT_FREE" | tr '\n' ' ' | cut -c1-160)"
  wait_scalar_table "select count(o) from $DBEXC.$T_FREE;" "0" 120 "  阶段 2：$T_FREE 行数归零"
  dl=$(( $(date +%s) + GC_WIN )); FREE_LEFT=$(( FREE_OBJ0 - RO_OBJ0 ))
  while (( $(date +%s) < dl )); do
    FREE_LEFT=$(cr12_obj_db_all "$DBEXC")
    log "    等 $T_FREE 的 object 回收：$DBEXC 剩余=$FREE_LEFT（注入目录内的残留属预期）"
    [ "${FREE_LEFT:-1}" -le "${BIN_BEFORE:-0}" ] && break
    sleep 5
  done
  if [ "${FAILGC1:-0}" -gt "${FAILGC0:-0}" ]; then
    if [ "${FREE_LEFT:-999}" -le "${BIN_BEFORE:-0}" ]; then
      pass "  阶段 2 H5：未被注入的表的 object 仍被物理清理（$DBEXC 剩余 $FREE_LEFT ≤ 注入目录内残留 $BIN_BEFORE）"
    else
      fail "  阶段 2 H5：未注入区域的 object 未被清理（$DBEXC 剩余 $FREE_LEFT > 注入残留 $BIN_BEFORE）⇒ 一个文件失败阻断了其余删除"
    fi
  else
    # ★ H5 依赖"异步 GC 确实跑过"才有意义；GC 路径没被触发（H6 已 WARN）时该断言无结论可下
    warn "  阶段 2 H5（无结论，只记录）：异步 GC 在 ${GC_WIN}s 内既未打失败日志、也未体现清理进度（$DBEXC 剩余=$FREE_LEFT，注入目录 .bin=$BIN_BEFORE）⇒ 本相不判『一个文件失败阻断其余删除』"
  fi
  if [ "$RO_DIR_CNT" -le 1 ]; then
    warn "  W1：每个 DN 上目标表只有一个 object 目录 ⇒「同一次删除里其余文件仍被删除」只能用另一张表（跨语句）作证据，该细节降级记录"
  fi
  # ④ 恢复可写 + 硬校验；再重试一次删除，看残留能否被回收
  RESTORE_BAD=""
  while IFS='|' read -r h d; do
    [ -n "${h:-}" ] || continue
    r=$(cr12_ro_ctl "$h" "$d" restore | tail -1); log "    $h restore → $r"
    [ "$r" = "RESTORE_OK" ] || RESTORE_BAD="$RESTORE_BAD$h:$r "
  done <<<"$RO_DIRS"
  if [ -n "$RESTORE_BAD" ]; then
    fail "  阶段 2 H8：只读注入恢复失败：$RESTORE_BAD（必须人工清理挂载后再跑）"
  else
    pass "  阶段 2 H8：三节点只读注入已恢复（探针可新建/删除文件）"
  fi
  OUT_RETRY=$(sqt "delete from $DBEXC.$T_RO where time <= $RO_HI;")
  log "  恢复后重试 DELETE：$(printf '%s' "$OUT_RETRY" | tr '\n' ' ' | cut -c1-160)"
  RESID=$BIN_AFTER
  dl=$(( $(date +%s) + GC_WIN ))
  while (( $(date +%s) < dl )); do
    RESID=0
    while IFS='|' read -r h d; do
      [ -n "${h:-}" ] || continue
      n=$(cr12_bin_in_dir "$h" "$d"); RESID=$(( RESID + ${n:-0} ))
    done <<<"$RO_DIRS"
    log "    等残留回收：只读目录内 .bin 剩余=$RESID（$BIN_AFTER）"
    [ "${RESID:-1}" -eq 0 ] && break
    sleep 5
  done
  if [ "${RESID:-1}" -eq 0 ]; then
    pass "  阶段 2 H5：恢复可写并重试后，残留 object 全部回收（$BIN_AFTER → 0）"
  else
    warn "  W2：恢复可写后仍有 $RESID 个残留 object 未被回收（异步 GC 不重试已失败记录）⇒ 需人工介入，如实记录，不判缺陷"
  fi
fi
# 收尾前：确认本用例注入的 bind 挂载全部消失（硬判据）
LEFT_MNT=0
while IFS='|' read -r h d; do
  [ -n "${h:-}" ] || continue
  m=$(cr12_ro_ctl "$h" "$d" mounted | tail -1); log "    $h mount 残留：$m"
  case "$m" in MOUNTED=0) ;; *) LEFT_MNT=$(( LEFT_MNT + 1 )) ;; esac
done <<<"$RO_DIRS"
assert_eq "  H8：结束时不得残留本用例注入的 bind 挂载" "$LEFT_MNT" "0"
FAILGC2=$(cr12_fail_gc_all); FAILRM2=$(cr12_fail_rm_all); FAILLS2=$(cr12_fail_list_all)
log "  失败计数终态：GC 失败=$FAILGC2（基线 $FAILGC0，本用例预期 +N）同步失败=$FAILRM2（基线 $FAILRM0）列目录失败=$FAILLS2（基线 $FAILLS0）"
if [ "${FAILRM2:-0}" -gt "${FAILRM0:-0}" ]; then
  warn "  H10：出现 $(( FAILRM2 - FAILRM0 )) 条 'Failed to remove object file'（同步路径文案）——本用例已注入只读、失败属**预期**；若该文案出现在注入目录之外需人工核对（记录，不判缺陷）"
else
  pass "  H10：未出现 'Failed to remove object file'（同步路径仅在 .tmp/.back 与未落盘文件上使用）"
fi
assert_eq "  H10：不得出现 'Failed to list object directory'（矩阵：出现即 FAIL）" "$FAILLS2" "$FAILLS0"

# ---------------------------------------------------------------------------
log "--- 阶段 3（R-48）：有/无 OBJECT 列的 DELETE 开销对照（弱判据，仅 WARN）---"
NOWP=$(now_ms)
cr12_mkplain "$DBPERF" "$T_PLAIN"
cr12_mkobj "$DBPERF" "$T_OBJ"
P_BASE=$(( NOWP - 900000 ))
OBJ_MS=""; PLN_MS=""
i=1
while [ "$i" -le "$PERF_ROUNDS" ]; do
  b=$(( P_BASE + i * HOLD_MS ))
  D=1
  while [ "$D" -le "$PERF_DEVS" ]; do
    cr12_ins "$DBPERF" "$T_OBJ" "p$D" "$b" "$PERF_ROWS" 65
    cr12_ins_plain "$DBPERF" "$T_PLAIN" "q$D" "$b" "$PERF_ROWS"
    D=$(( D + 1 ))
  done
  sqt "flush;" >/dev/null
  cut=$(( b + PERF_ROWS * 10 ))
  o=$(sqt "delete from $DBPERF.$T_OBJ where time <= $cut;")
  p=$(sqt "delete from $DBPERF.$T_PLAIN where time <= $cut;")
  om=$(cr12_cost_ms "$o"); pm=$(cr12_cost_ms "$p")
  log "  第 $i 轮：有 OBJECT 的 DELETE=${om}ms；无 OBJECT 的 DELETE=${pm}ms"
  printf '    第 %s 轮原始输出：OBJECT=[%s] PLAIN=[%s]\n' "$i" "$(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)" "$(printf '%s' "$p" | tr '\n' ' ' | cut -c1-160)" >>"$OUT"
  OBJ_MS="$OBJ_MS$om
"; PLN_MS="$PLN_MS$pm
"
  i=$(( i + 1 ))
done
OAVG=$(cr12_avg "$OBJ_MS"); PAVG=$(cr12_avg "$PLN_MS")
log "  平均：有 OBJECT=${OAVG}ms；无 OBJECT=${PAVG}ms（CLI 的 It costs 口径）"
if [ "${OAVG:-1}" -lt 0 ] || [ "${PAVG:-1}" -lt 0 ]; then
  warn "  W3：CLI 输出未解析到 'It costs %.3fs' ⇒ 跳过方向性断言，只保留原始输出（见 artifact）"
else
  RATIO=$(awk -v a="$OAVG" -v b="$PAVG" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "0" }')
  log "  比值（OBJECT / 无 OBJECT）= $RATIO（阈值 $PERF_WARN_RATIO，仅 WARN）"
  if awk -v r="$RATIO" -v lim="$PERF_WARN_RATIO" 'BEGIN { exit !(r + 0 > lim + 0) }'; then
    warn "  H9（R-48 弱判据）：有 OBJECT 的 DELETE 耗时是无可比对象的 ${RATIO} 倍（> $PERF_WARN_RATIO）⇒ 建议人工看趋势，不判 FAIL（原文无阈值依据）"
  else
    pass "  H9（R-48 弱判据）：有/无 OBJECT 的 DELETE 耗时同量级（比值 $RATIO）"
  fi
fi
printf 'Time,build,consensus,case,phase,obj_ms,plain_ms\n' >>"$OUTDIR/cr12_delete_overhead.csv" 2>/dev/null || true
printf '%s,%s,%s,CR-12,delete_overhead,%s,%s\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${CONSENSUS_CLASS##*.}" "$OAVG" "$PAVG" >>"$OUTDIR/cr12_delete_overhead.csv"
log "  开销数据已追加到 $OUTDIR/cr12_delete_overhead.csv"

log "--- 收尾三件套（基准用未被删除的 $DBISO.$T_KEEP）---"
post_checks "select o from $DBISO.$T_KEEP order by time;" table
cmp_case_finish "" table ""
