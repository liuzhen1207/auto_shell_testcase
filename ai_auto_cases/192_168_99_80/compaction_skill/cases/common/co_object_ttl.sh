#!/bin/bash
# ============================================================================
# CO-41 表模型 OBJECT 类型合并与 TTL/deletion 清理语义（D7-1 / D7-2 / D7-3 / D7-4）
#   覆盖（设计文档 V2.0.8.1「OBJECT 类型的合并和 TTL」；官方测试文档**未覆盖**）：
#     D7-1 OBJECT 在 TsFile 里**只存引用**，真实二进制在磁盘另一处（合并需适配）
#     D7-2 合并**只清理因 TTL 过期的 object 文件，不清理因 deletion 删除的**
#     D7-3 settle 对 **fully dirty** 文件：先按 table 粒度扫描并清理 object，**再删除 TsFile**
#     D7-4 对 object 数据**逐点扫描**，point.timestamp 超过 TTL 才执行真实 object 文件删除
#     D7-6 复用参数 `ttl_check_interval`（重启生效）
#   规格出处：docs/OFFICIAL_COVERAGE.md §4.2 CO-41、§5 第 32/33/34 项
#
# ---------------------------------------------------------------------------
# 现场机制（RC7 源码 + 2026-10-15 首跑日志实测）——决定了本用例的判据写法：
#
#   ① object 文件的真实删除由 **TTL 检查线程**独立完成，与合并开关无关：
#      TTLScheduleTask → DataRegion.executeTTLCheckForObjectFiles →
#      CompactionUtils.executeTTLCheckObjectFilesForTableModel（**表 TTL=INF 时直接 continue**），
#      删除判据 = object 文件名里的 pointTime < now − ttl − 60s（`checkTTLAndDeleteExpiredObjectFile`
#      就是按文件名前缀解析 pointTime），即 **D7-4 的"按点判 TTL"**。
#      ⇒ A 相"过期点的 object 被删、未过期点的 object 一个不删"是**本相的核心硬判据**。
#
#   ② **DELETE 删掉的行，其 object 文件由另一个独立的 GC 线程回收**（首跑实测：DELETE 后 ~6s，
#      线程 `pool-88-IoTDB-Object-GC-1`、logger `o.a.i.d.u.DataNodeObjectFileService`；旧版源码里
#      对应 DataRegion 按 TableDeletionEntry 遍历 object 目录 + ObjectTypeUtils.deleteObjectPath）。
#      这是**删除触发的独立机制，不是合并** ⇒ B 相对"合并窗口内 object 总数不变"+"TTL 路径
#      （CompactionUtils）删除数不变"做硬断言，GC 路径的删除只记录/告警（防误判）。
#
#   ③ settle 选择（SettleSelectorImpl.selectFileBaseOnDirtyData，v20121 分支 :258-304）：
#      **表模型的 TTL 是表级**的 ⇒ 同一 TsFile 内每个设备都 hasSetTTL=true，只要有一个设备
#      **仍有存活点**（isDeleted=false）就在 :281-286 直接 `return NOT_SATISFIED`（整文件出局，
#      与 expired_data_ratio / max_expired_time=INF 都无关；:312 还会把 hasExpiredTooLong 强制为 false）。
#      因此表模型下 `deletedDeviceRatio ∈ (0,1)` 的 PARTIALLY_DIRTY（:313-317）**不可达**：
#      要么"全部设备都过期"⇒ :308 FULLY_DIRTY 整文件删除（= C 相、以及 A 相的 d2 文件），要么直接出局。
#      ⇒ A 相 d1 的文件（新旧混排、仍有存活点）**按设计永远不会被 settle 选中**：它的过期点靠 ①
#      的按点 object 清理回收，但**行**级物理删除不会发生（TTL 复位 INF 后这些行重新可见）。
#      首轮把"过期行被物理删除（TTL=INF 后行数回到 40）"当硬判据 ⇒ 2 条假 FAIL（第 2 条是同根因的指纹下游）。
#      注：报告 §③ 的"方案 A：同一 TsFile 内 ≥1 设备整体过期 + ≥1 设备仍存活"在**表模型**下**不成立**
#      （表模型没有"无 TTL 的设备"来豁免 :281-286；那份做法只在树模型设备级 TTL 下有效）
#      ⇒ 本用例取报告的方案 B：判据与场景匹配，期望值由**实测到的选择器行为**驱动（见 A 相收尾）。
#      A 相的"settle 任务数"仍只作"清理是否推进"的证据，机制归属降级 WARN
#      （首跑把这条当硬判据，出现过 inner/settle 竞争导致的假 FAIL）。
#
#   ④ inner 合并**至少需要 2 个文件**（selector `if (totalFileNum < 2) return;`），候选门槛 =
#      `inner_compaction_candidate_file_num`(=${CMP_CANDIDATE_NUM}) ⇒ C 相**只写 1 个 TsFile**，
#      inner 无法插手，必然走 settle（首跑 C 相写了 3 个文件被 inner 抢走 ⇒ settle=0 假 FAIL）。
#
# ---------------------------------------------------------------------------
# 三相设计（每相独立库；**库名不带 root. 前缀** —— 表模型库名即数据目录名，日志前缀也是它）：
#   A 相 coobj ：d1 同一个 TsFile 里**新旧点混排**（旧点 -900s、新点 -10s 同一条 INSERT）
#                + d2 整文件旧点（独立 TsFile）
#                ⇒ ALTER TABLE SET ttl=<动态计算> 后：
#                   · 查询侧只剩新点（TTL 过滤）
#                   · d2 的文件 fully dirty ⇒ 被 settle/inner 删掉（TsFile 数下降，本相硬判据）
#                   · d1 的文件 NOT_SATISFIED（仍有存活点 ⇒ 不是 settle 的对象，见机制③）
#                     ⇒ 过期点靠按点清理回收，**过期"行"按设计不物理删除**（TTL=INF 后重新可见）
#                   · **过期点的 object 真实文件被删、未过期点的一个不删**（D7-4，逐点判据）
#                ⚠️ TTL 必须**动态计算**：首跑用固定 100s，而从"取 NOW 基准"到"ALTER 生效"之间
#                   被 ensure_closed 白等 75s + object 稳定等待 40s ⇒ 新点（-10s）也过了 100s，
#                   于是"新点"全变过期 ⇒ 3 条假 FAIL（count(o)=0 / 残留 object=0 / TTL=INF 后行数=0）。
#                   现在：ttl = (ALTER 时刻 − 新点基准) + 窗口 + 180s 余量 ⇒ 新点在整相内都活着，
#                   旧点（-900s）必然过期且必然超过 now−ttl−60s。
#   B 相 coobj2：3 个 TsFile（无 TTL）→ `DELETE FROM … WHERE time <= T` 删掉 1/3 → 触发 inner 合并
#                ⇒ **合并窗口内 object 真实文件数必须完全不变**（D7-2 的核心对照），
#                  且 TTL 路径（CompactionUtils）删除数必须为 0（表 TTL=INF ⇒ TTL 检查跳过该表）。
#   C 相 coobj3：**1 个 TsFile** → `ttl=1000` 使全部点过期 ⇒ 整库 fully dirty
#                ⇒ settle 删除 TsFile 且 **object 真实文件清理为 0**（D7-3；终态无孤儿引用）。
#
# 【首轮复跑验收点（2026-10-16 rc7 V1 2 条 FAIL 定性为**用例场景与源码语义不匹配**后的修复，见 _scratch/CO384041_TRIAGE.md §2.3）】
#   ① `fail_flag=0`；A 相必须打印实测的 `fully_dirty / partially_dirty` settle 任务数（M 决定"行能否被物理删除"的期望值）。
#   ② A 相硬判据（本轮已 PASS，不得回退）：过期点 object 逐点清零、未过期点 object 一个不删（$(( C41_ROWS * 3 )) 保留）、
#      d2 整文件过期的 TsFile 被删除、`TTL=INF` 前后**同一批存活新点**的 OBJECT 取值指纹逐字节一致。
#   ③ C 相（D7-3 的 settle 路径）与 B 相（D7-2 合并不删 object）的硬判据不得回退；TTL=INF 后行数按实测机制取值（见 A 相收尾）。
#
# ---------------------------------------------------------------------------
# 【RC8 V1→V2 口径修正（2026-10-17；报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.6 / §④ P0-2+P1-3）】
#   V1 PASS 406s f0 → V2 FAIL 659s **f8**，8 条分三类，全部在用例侧：
#   ① 两条「场景无效：各副本 TsFile 数=77=5 78=3 79=3（期望各 2）」= **"三副本 TsFile 数必须相等"**：
#      V2 follower 额外持有复制来的 TsFile（DataRegion.java:4984/5009），5/3/3、4/4/4 是正常形态。
#      ⇒ `c41_assert_ts` 改成**判据集口径**（V1=全部副本 / V2=leader），follower 差异只 WARN。
#   ② 一条「C 相 TsFile 数未归零（2，各副本 77=0 78=0 79=0）」= **判据用 cmp_all_sum、回显用 seq_cnt**：
#      V2 下 follower 的复制文件全在 unseq ⇒ all_sum 结构上永不归零。⇒ 判据改 `cmp_seq_sum`（P0-2）。
#   ③ 一条「A 相 TTL=INF 后可见行数 40 ≠ 80」= 期望值依赖**副本文件切分**（V2 下 d1 只剩旧点的文件
#      变成 FULLY_DIRTY 被整文件删掉）⇒ 期望值取 {40, 80}，紧随其后的"存活新点必在 + 取值指纹"仍硬判。
#   ④ 四条「停 DN 后经 X 查询与基准不一致（40 → 80 → 120）」= 逐副本 settle 清理进度不同（本地文件操作、
#      不经共识；RC7 已定性为"副本物理状态差异，非共识丢数据"）⇒ 由 `lib/common.sh` 的
#      consistency_check 统一口径处理：取基准前先 flush + 等逐副本可见；V2 只容忍"未 seal 尾部"的缺口，
#      而本用例查的是**聚合值**（`select count(o)` 一行结果）⇒ 不满足"子集"条件，仍是硬判据。
#      **这四条本轮预计仍然 FAIL**（属"副本可见结果是否必须一致"的独立议题，见报告 §④.9，需研发口径）。
# ---------------------------------------------------------------------------
#
# OBJECT 事实（现场实测）：
#   · 目录 `data/datanode/data/object/<regionId>/<base32(table)>[/tags]/{pointTime}_{tsVersion}.bin`
#     ⇒ 本用例用"全局 object 总数（增量）"+"某库 region 目录内的精确计数"+"按文件名 pointTime
#       过滤的逐点计数"三种口径；逐点计数不可用（命名约定变化）时自动降级 WARN。
#   · 删除判据 `pointTime < now - ttl - 60s`（**额外 60s 缓冲**）⇒ 清理窗口要留 ≥ TTL+60s+检查周期；
#     删除日志 `Remove object file … size is …`（logger OBJECT_DELETION → log_datanode_object_deletion.log）。
#
# 判据双信号（每相）：完成数增量（settle / inner finishes）**且**文件数下降。
#   注：A 相的 d1 文件不是 settle 对象（见机制③），因此 A 的"文件数下降"以 **object 真实文件数**
#       与 d2 全过期文件的删除为准（避免误判）。
#
# 用法： bash co_object_ttl.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_object_ttl_${DATA_CONSENSUS}"

# ---------------------------- 规模 / 参数（顶部变量） ----------------------------
DBA=coobj                       # A 相：TTL 过期（d1 同文件新旧混排 + d2 整文件旧点）
DBB=coobj2                      # B 相：仅 DELETE、无 TTL（D7-2 对照）
DBC=coobj3                      # C 相：1 个 TsFile + TTL 极小 ⇒ fully dirty（D7-3）
C41_ROWS=${C41_ROWS:-40}        # 每设备/每批点数（= 每行的 object 文件数，实测 1:1）
C41_OLD_MS=${C41_OLD_MS:-900000}   # A 相"旧点"回拨 900s（必须 ≫ TTL+60s 缓冲 + 窗口）
C41_LIVE_MS=${C41_LIVE_MS:-10000}  # A 相"新点"回拨 10s（TTL 动态计算时以它为基准）
C41_TTL_TINY_MS=${C41_TTL_TINY_MS:-1000}  # C 相 TTL=1s ⇒ 全部过期
C41_OBJ_WIN=${C41_OBJ_WIN:-120}    # 等 object/TsFile 清理的窗口（秒）
C41_WIN=${C41_WIN:-90}             # 等合并推进的窗口（秒）
C41_READY_W=${C41_READY_W:-60}     # 等"落盘就绪"（TsFile 数 + Async close）的上限（秒）
C41_STABLE_W=${C41_STABLE_W:-30}   # 等 object 文件数稳定的上限（秒）
C41_MECH_GRACE=${C41_MECH_GRACE:-20}  # 终态已达成但机制计数（settle）迟迟不涨时的宽限（秒）
C41_TTL_IVL=${C41_TTL_IVL:-5000}   # ttl_check_interval（重启生效，必须与 env 一致）

# ---------------------------- OBJECT / TTL helper ----------------------------
# 全局 object 真实文件数（所有 DN 求和；`*object*` 兼容 data/object 与 data/datanode/data/object 两种布局）
c41_obj_node(){ local h=$1 v; v=$(sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
c41_obj_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(c41_obj_node "$h") )); done; echo "${s:-0}"; }
# 等 object 文件数稳定（连续两次采样相同）后返回 —— object 文件在 flush/close 之后还可能继续落盘，
# 直接用瞬时值当"清理前基线"会把后来的落盘算成"没下降"（踩坑预防）。最多等 w 秒。
c41_obj_stable(){ local w=${1:-40} dl a b
  dl=$(( $(date +%s) + w ))
  a=$(c41_obj_all); b=$a
  while (( $(date +%s) < dl )); do
    sleep 5; b=$(c41_obj_all)
    [ "${b:-0}" = "${a:-0}" ] && { echo "${b:-0}"; return 0; }
    a=$b
  done
  echo "${b:-0}"; }
# 按 object 文件名里的 pointTime 过滤真实文件数（文件名约定 `<pointTime>_<version>.bin`，与
# CompactionUtils.checkTTLAndDeleteExpiredObjectFile 的解析方式一致）：c41_obj_ts ge|lt <阈值>
# ⚠️ ge/lt 是本函数的写法，真正下发的必须是 awk 的 >= / <（awk 没有 ge/lt 运算符，写错会静默算 0）
c41_obj_ts(){ local op=$1 th=$2 h v s=0 awkop
  case "$op" in
    ge) awkop='>=' ;;
    lt) awkop='<' ;;
    *)  awkop="$op" ;;
  esac
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' -printf '%f\n' 2>/dev/null | cut -d_ -f1 | awk -v t=$th '\$1 ~ /^[0-9]+\$/ && \$1 $awkop t' | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done
  echo "${s:-0}"; }
# 某库的 object 真实文件数（按 region 目录精确匹配；现场若目录结构不同会返回 0 ⇒ 只作信息性证据）
c41_obj_db_node(){ local h=$1 db=$2 rid v s=0
  for rid in $(ttl_region_ids "$h" "$db"); do
    v=$(sshx "$h" "find $DB_DIR/data/datanode/data/object/$rid -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done
  echo "${s:-0}"; }
c41_obj_db_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(c41_obj_db_node "$h" "$1") )); done; echo "${s:-0}"; }
# object 删除日志条数（logger OBJECT_DELETION）。**必须区分两条路径**：
#   · CompactionUtils        = TTL 检查线程按点判 TTL（D7-4，表 TTL=INF 时不会出现）
#   · DataNodeObjectFileService / ObjectTypeUtils = 删除数据触发的独立 object GC（与合并无关）
c41_del_node(){ local h=$1 pat=$2 v
  v=$(sshx "$h" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | grep -c '$pat'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
c41_del_ttl_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(c41_del_node "$h" 'CompactionUtils') )); done; echo "${s:-0}"; }
c41_del_gc_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(c41_del_node "$h" 'DataNodeObjectFileService') )); done; echo "${s:-0}"; }
# 某库的 settle 任务数（权威信号，全部 DN 求和）
c41_settle_all(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(settle_task_for_db "$h" "$1") )); done; echo "${s:-0}"; }
# 某库"含部分过期文件"的 settle 任务数（日志行 `... starts with N fully_dirty files and M partially_dirty files`，
# M ≥ 1 即命中）。它是"A 相过期**行**能否被物理删除"的**前提**：源码 SettleSelectorImpl 对
# "文件里仍有存活的 TTL 设备"直接返回 NOT_SATISFIED（见文件头机制③），此时 M 恒为 0。
c41_settle_partial_all(){ local h s=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "grep -hE '(^|[- ])(root\.)?$1-[0-9]+ \[Compaction\] SettleCompaction task starts with' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -cE '[1-9][0-9]* partially_dirty'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${v:-0} ))
  done; echo "${s:-0}"; }
# "存活新点"（时间戳最大的 n 行）的 OBJECT 取值指纹：整表按 time 升序后取**最后 n 行**再摘要。
# 这样"TTL 生效时（只见 40 行）"与"TTL=INF 后（80 行）"比较的是**同一批行**；原实现直接比整表指纹，
# 行集从 40 变 80 ⇒ 必然不等（首轮第 2 条假 FAIL）。窗口内新点时间戳恒为全表最大 ⇒"最后 n 行 = 存活新点"。
c41_live_fp(){ local db=$1 n=$2
  sqt "select o from $db.t1 order by time;" 2>/dev/null | table_rows | tail -n "$n" | md5sum | cut -c1-10; }
# 表模型建库 + OBJECT 列表（列：dev TAG / v INT64 FIELD / o OBJECT FIELD）
c41_mkobj(){ local db=$1 t=$2 out
  sql_lines_table "create database $db;" >/dev/null
  out=$(sqt "create table $db.$t (dev STRING TAG, v INT64 FIELD, o OBJECT FIELD);")
  printf '%s' "$out" | grep -q 'successfully' || fail "  建表 $db.$t 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  out=$(sqt "show tables from $db;")
  printf '%s' "$out" | grep -q "$t" && pass "  建表成功：$db.$t" || fail "  场景无效：$db.$t 未建成"
  printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"; }
# 写一批 OBJECT 点：c41_ins_obj <db> <table> <dev> <base_ms> <n> <hex>
c41_ins_obj(){ local db=$1 t=$2 dev=$3 base=$4 n=$5 hex=$6 k kv="" out
  for ((k=1;k<=n;k++)); do kv="$kv($(( base + k * 10 )),'$dev',$k,to_object(true,0,X'$hex')),"; done
  out=$(sqt "insert into $db.$t (time, dev, v, o) values ${kv%,};")
  printf '%s' "$out" | grep -q 'successfully' || fail "  写入 $db.$t dev=$dev 失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  printf '%s\n' "$out" | grep -q 'successfully' && log "    已写入 $db.$t dev=$dev $n 点（ts 基准 $base，object 载荷 X'$hex'）"; }
# A 相专用：用**一条** INSERT 写 d1 的新旧混排点（同一个 memtable ⇒ 同一个 TsFile ⇒ 构造"文件内部分过期"，
# 否则两次 INSERT 之间若发生刷盘，旧点会单独成文件、退化成 fully dirty 的 D7-3 路径，测不到 D7-4 逐点扫描）
c41_ins_mixed(){ local db=$1 t=$2 k kv="" out
  for ((k=1;k<=C41_ROWS;k++)); do kv="$kv($(( OLD_BASE + k * 10 )),'d1',$k,to_object(true,0,X'6F')),"; done
  for ((k=1;k<=C41_ROWS;k++)); do kv="$kv($(( LIVE_BASE + k * 10 )),'d1',$(( C41_ROWS + k )),to_object(true,0,X'61')),"; done
  out=$(sqt "insert into $db.$t (time, dev, v, o) values ${kv%,};")
  printf '%s' "$out" | grep -q 'successfully' || fail "  A 相 d1 混排写入失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  printf '%s\n' "$out" | grep -q 'successfully' && log "  A 相：d1 一条 INSERT 写 $(( C41_ROWS * 2 )) 点（旧点基准 $OLD_BASE / 新点基准 $LIVE_BASE）"; }
# 可见行数（OBJECT 列非空计数 = TTL 过滤后的行数）
c41_rows(){ local db=$1 v; v=$(scalar "$(sqt "select count(o) from $db.t1;")"); echo "${v:-0}"; }
# ---------------------------------------------------------------- A 相的 TTL 感知一致性判据
# 语义（研发确认 2026-10-21）：ttl=INF 后"未被物理删除的过期旧点"会重新可见 —— **属预期**；
#   而 STRONG 读固定读副本列表第 0 个（AbstractFragmentParallelPlanner.java:120/137-144），
#   各副本的 TTL/settle 清理是**本地异步**的（SettleSelectorImpl.java:281-286/308）
#   ⇒ 停副本后读数可能变大。
# 判据（**行级**，不能用聚合值——"40 vs 80" 是两个不同字符串，无法表达"只多不少"）：
#   ① 基准（三副本在线）的每一行都必须出现在每个"停副本"格（**一行不能少**）；
#   ② 多出来的行必须 **time < LIVE_BASE**（= A 相过期旧点区间）⇒ WARN（属预期）；
#      多出 time >= LIVE_BASE 的行（凭空新增/重复新点）⇒ FAIL；
#   ③ 查询报错/结果为空 ⇒ FAIL。
c41_cons_ttl_aware(){ local db=$1 live_base=$2 h on basef curf rc line
  local q="select dev, time from $db.t1 order by time;"
  sq "flush;" >/dev/null 2>&1
  basef="$ART/cons_base_${db}.txt"
  query_result "${DN[0]}" table "$q" > "$basef" 2>&1
  local bn; bn=$(cons_rows_n "$(cat "$basef")")
  log "  基准（经 ${DN[0]}）：${bn} 行（$basef）"
  [ "${bn:-0}" -gt 0 ] && pass "  基准非空（${bn} 行）" || { fail "  场景无效：基准行数为 0（$basef）"; return 1; }
  local bad=0
  for h in "${DN[@]}"; do
    log "  --- 停 $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" >/dev/null 2>&1
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  停 $h 后集群仍显示 Running"
    for on in "${DN[@]}"; do
      [ "$on" = "$h" ] && continue
      curf="$ART/cons_stop${h##*.}_via_${on##*.}_${db}.txt"
      query_result "$on" table "$q" > "$curf" 2>&1
      line=$(python3 - "$basef" "$curf" "$live_base" "${h##*.}" "${on##*.}" <<'PY'
import sys
basef, curf, live, down, via = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
def load(p):
    s = []
    for line in open(p, encoding="utf-8", errors="replace"):
        t = line.strip()
        if not t.startswith("|") or t.startswith("|dev") or t.startswith("+") or t.startswith("|Time"):
            continue
        c = [x.strip() for x in t.strip("|").split("|")]
        if len(c) >= 2 and c[0].startswith("d"):
            s.append((c[0], c[1]))
    return s
def ms(ts):
    from datetime import datetime
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "")).timestamp() * 1000)
    except Exception:
        return None
b, cur = load(basef), load(curf)
bs, cs = set(b), set(cur)
if not cs:
    print("FAIL 停 %s 时经 %s 查询：结果为空（查询失败或副本无数据）" % (down, via)); sys.exit(1)
missing = bs - cs
extra = [k for k in cs - bs]
if missing:
    print("FAIL 停 %s 时经 %s 查询：**少了 %d 行**（基准 %d / 实测 %d），例 %s" % (down, via, len(missing), len(bs), len(cs), sorted(missing)[:3])); sys.exit(1)
not_old = [k for k in extra if (ms(k[1]) is None) or (ms(k[1]) >= live)]
if not_old:
    print("FAIL 停 %s 时经 %s 查询：多出 %d 行不属于过期旧点（time >= LIVE_BASE 或时间不可解析），例 %s" % (down, via, len(not_old), not_old[:3])); sys.exit(1)
print("PASS 停 %s 时经 %s 查询：基准 %d 行一行不少；多出 %d 行且全部是 A 相的过期旧点（time < LIVE_BASE）⇒ 旧行复活属预期（ttl=INF + 各副本本地异步清理 + STRONG 固定读副本列表第 0 个）" % (down, via, len(bs), len(extra)))
PY
)
      rc=$?
      case "$line" in
        PASS*) pass "$line" ;;
        FAIL*) fail "${line#FAIL }"; bad=$(( bad + 1 )) ;;
        *)     fail "  停 ${h##*.} 时经 ${on##*.} 查询：判据脚本无输出（rc=$rc）"; bad=$(( bad + 1 )) ;;
      esac
    done
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h##*.}.log 2>&1 </dev/null &" >/dev/null 2>&1
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "  $h 未恢复 Running"
  done
  [ "$bad" = 0 ]
}
# 某库各副本 TsFile 数串（形如 "77:2 78:2 79:2 "）
c41_ts(){ cmp_per_node cmp_seq_cnt "$1"; }
# 断言 TsFile 数：**判据集**（V1=全部副本 / V2=region leader，口径见 lib/cmp.sh）== want。
# 【RC8 口径修正（2026-10-17）】旧断言要求"**各副本** TsFile 数都 == want"，V2 下 follower 会额外
#   持有复制来的 TsFile（DataRegion.java:4984 setSeq(false)/:5009）⇒ 实测 5/3/3、4/4/4 是**正常形态**，
#   旧口径直接判"场景无效"（V2 的 2 条 FAIL）。现在判据集必须达标，follower 差异只 WARN 并打印逐副本。
# 【F6 修正（2026-10-20）】判据集"TsFile 数 == want"过于依赖**文件切分**：RC8 V2 实测 coobj 判据集=5 个
#   seq 文件（V1 是 2），场景语义（同文件新旧混排 + 整文件过期）仍然成立 ⇒ 改为 **≥ want**，
#   超出只 WARN 并打印实际值；不足仍判场景无效。
c41_assert_ts(){ local db=$1 want=$2 h n ok=1 spec="" others="" judge
  judge=$(cmp_judge_nodes "$db")
  for h in $judge; do n=$(cmp_seq_cnt "$h" "$db"); spec="$spec${h##*.}:${n:-0} "; [ "${n:-0}" -ge "$want" ] || ok=0; done
  for h in "${DN[@]}"; do case " $judge " in *" $h "*) continue ;; esac
    others="$others${h##*.}:$(cmp_seq_cnt "$h" "$db") "; done
  if [ "$ok" = 1 ]; then
    pass "  场景有效性：$db 判据集 TsFile 数 ≥ $want（实测 $spec）"
    if [ -n "${others// /}" ]; then
      warn "  记录：$db 非判据副本 TsFile 数 $others 与判据集（$spec）不同 —— V2 follower 额外持有复制来的 TsFile（DataRegion.java:4984/5009，设计差异、非缺陷）"
    fi
  else
    fail "  场景无效：$db 判据集 TsFile 数 < $want（实测 $spec；各副本 $(c41_ts "$db")）"
  fi }
# 该表当前 TTL（SHOW TABLES 的 TableName|TTL(ms)）
# ⚠️ 必须拆成两句：`set -u` 下 `local db=$1 t=$2 f "$(cmd "$db")"` 会对**同一条 local 命令**里的
#    `$db` 先做词展开（此时 db 还没赋值）⇒ "db: unbound variable" 且静默返回空（本项目反复踩过）
c41_ttl_of(){ local db=$1 t=$2 out
  out=$(sqt "show tables from $db;")
  table_ttl "$out" "$t"; }
# 等"真正落盘"：各副本 TsFile 数 == want 且都出现过 `Async close tsfile` 事件（未 close 的文件不参与
# settle 选择）。**取代 ensure_closed**：后者要求"再 flush 出新 close 事件"，但 memtable 往往已经自动
# 刷盘 ⇒ 必然等满 3×25s 并刷出"某副本未落盘"的假告警（首跑三相各白等 75s，还把 TTL 时序拖崩）。
# 注：ttl_close_cnt 的匹配是子串（db=coobj 也会匹配 coobj2/3），本用例按 A→B→C 顺序执行、库依次创建，
#     所以每个相位的匹配不会串到后面的库。
c41_ready(){ local db=$1 want=$2 w=${3:-$C41_READY_W} dl h n ok judge
  dl=$(( $(date +%s) + w ))
  while (( $(date +%s) < dl )); do
    ok=1; judge=$(cmp_judge_nodes "$db")
    # 【RC8 口径修正】落盘就绪只要求**判据集**（V1=全部副本 / V2=leader）：V2 follower 不 flush 自己的
    #   memtable、整轮 `Async close` 可能是 0 条（实测 coobj 77:0）⇒ 旧口径必然等满 60s 并报"落盘未确认"。
    for h in $judge; do
      n=$(cmp_seq_cnt "$h" "$db"); [ "${n:-0}" -ge "$want" ] || ok=0
      n=$(ttl_close_cnt "$h" "$db"); [ "${n:-0}" -ge "$want" ] || ok=0
    done
    if [ "$ok" = 1 ]; then echo "判据集($judge) TsFile ≥$want 且 close 事件 ≥$want（$(c41_ts "$db")）"; return 0; fi
    sq "flush;" >/dev/null 2>&1
    sleep 4
  done
  echo "落盘未确认（判据集=$(cmp_judge_nodes "$db") TsFile=$(c41_ts "$db") close=$(ttl_close_snapshot "$db")）"; return 1
}

# ============================================================================
log "--- 集群准备（ttl_check_interval=${C41_TTL_IVL}ms；seq 合并=true 才做 TTL 物理清理；M=INF、ratio 极小不拦部分过期）---"
export TTL_CHECK_INTERVAL_MS="$C41_TTL_IVL"
export MAX_EXPIRED_TIME_MS=9223372036854775807
export EXPIRED_DATA_RATIO=0.000001
EXTRA_CONF="enable_seq_space_compaction=true,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS}" cmp_cluster_prepare
assert_eq "  生效值 ttl_check_interval（重启生效键，走 env 写入并逐节点校验）" "$(cmp_eff "${DN[0]}" ttl_check_interval)" "$C41_TTL_IVL"
log "  生效值：enable_seq_space_compaction=$(cmp_eff "${DN[0]}" enable_seq_space_compaction) expired_data_ratio=$(cmp_eff "${DN[0]}" expired_data_ratio) max_expired_time=$(cmp_eff "${DN[0]}" max_expired_time)"

# ============================================================================
log "--- A 相（D7-1/D7-4）：TTL 过期 ⇒ 过期点的 object 真实文件被删、未过期点的一个不删 ---"
log "  能力探测：建 OBJECT 表并写入（若 DDL/存储路径与设计不符 ⇒ 场景不可构造，如实记录）"
cmp_compaction_off
NOW=$(now_ms)
OLD_BASE=$(( NOW - C41_OLD_MS ))      # 旧点基准（只用"年龄"判 TTL，绝对值不重要）
LIVE_BASE=$(( NOW - C41_LIVE_MS ))    # 新点基准（TTL 动态计算的锚点）
c41_mkobj "$DBA" t1
G_A0=$(c41_obj_all)
c41_ins_mixed "$DBA" t1                                              # d1：同一 TsFile 内旧点+新点
sqt "flush;" >/dev/null
c41_ins_obj "$DBA" t1 d2 "$OLD_BASE" "$C41_ROWS" 62                  # d2：整文件旧点（fully dirty）
sqt "flush;" >/dev/null
if READY_MSG=$(c41_ready "$DBA" 2); then log "  $DBA 落盘就绪：$READY_MSG"; else warn "  $DBA $READY_MSG"; fi

R_A=$(c41_rows "$DBA")
c41_assert_ts "$DBA" "2"
log "  A 相写入后：可见行数=$R_A（期望 $(( C41_ROWS * 3 ))）TsFile=$(c41_ts "$DBA")"
assert_eq "  A 相写入后 OBJECT 行数（TTL 未设）" "$R_A" "$(( C41_ROWS * 3 ))"
G_A1=$(c41_obj_stable "$C41_STABLE_W"); OBJ_A=$(( G_A1 - G_A0 ))
if [ "${OBJ_A:-0}" -gt 0 ]; then
  pass "  场景有效性：A 相产生了 object 真实文件 +$OBJ_A（全局计数 $G_A0 → $G_A1）"
else
  fail "  场景无效：未见 object 真实文件（+0）⇒ 该版本 OBJECT 存储路径/DDL 与设计不符或未落盘（场景不可构造）"
fi
# 场景有效性：object 文件数是"点数 × 副本数"的 1:1（决定后面的精确计数判据是否可用）
OBJ_DB_A1=$(c41_obj_db_all "$DBA")
SCEN_A=0
if [ "${OBJ_DB_A1:-0}" = "$(( C41_ROWS * 3 * 3 ))" ]; then
  SCEN_A=1; pass "  场景有效性：A 相 object 真实文件数=$OBJ_DB_A1（$(( C41_ROWS * 3 )) 点 × 3 副本，1:1）"
else
  warn "  场景有效性：A 相按 region 精确计数=$OBJ_DB_A1（期望 $(( C41_ROWS * 3 * 3 ))）⇒ object 与点非 1:1，精确计数判据降级为 WARN，只用总数趋势"
fi
# 逐点计数（按 object 文件名里的 pointTime）：未过期点 / 过期点各多少
OBJ_LIVE_pre=$(c41_obj_ts ge "$LIVE_BASE")
OBJ_OLD_pre=$(c41_obj_ts lt "$LIVE_BASE")
POINTWISE=0
if [ "${OBJ_LIVE_pre:-0}" = "$(( C41_ROWS * 3 ))" ] && [ "${OBJ_OLD_pre:-0}" = "$(( C41_ROWS * 2 * 3 ))" ]; then
  POINTWISE=1; pass "  场景有效性：object 文件名可按点区分（未过期点 $OBJ_LIVE_pre / 过期点 $OBJ_OLD_pre）"
else
  warn "  逐点计数与预期不符（未过期点 $OBJ_LIVE_pre，期望 $(( C41_ROWS * 3 ))；过期点 $OBJ_OLD_pre，期望 $(( C41_ROWS * 2 * 3 ))）⇒ 逐点判据降级为 WARN"
fi
log "  A 相 object 文件数（按 region 精确计数，信息性）：$OBJ_DB_A1"
# 清理前基线：**取写入后（设 TTL 之前）的值**（与首跑一致，避免漏掉下降信号）；
# settle 基线同样取设 TTL 之前。
DELT_A0=$(c41_del_ttl_all); DELG_A0=$(c41_del_gc_all)
TS_A1=$(cmp_all_sum "$DBA"); G_AW=$G_A1; SET_A0=$(c41_settle_all "$DBA")
# settle 任务里"含部分过期文件"（M ≥ 1）的条数：它是"A 相过期**行**能否被物理删除"的**前提**
# （源码 SettleSelectorImpl:281-286 对仍有存活点的文件返回 NOT_SATISFIED ⇒ M 恒为 0）。基线取在设 TTL 之前。
PART_A0=$(c41_settle_partial_all "$DBA")

# 动态 TTL：新点在**整相窗口**内保持存活（ttl > ALTER 时刻新点年龄 + (窗口+180s) 余量，注意换算成 ms），
# 旧点（-900s）则必然过期且必然超过 now−ttl−60s 的删除判据。
C41_EFF_TTL=$(( $(now_ms) - LIVE_BASE + (C41_OBJ_WIN + 180) * 1000 ))
AGE_OLD=$(( $(now_ms) - OLD_BASE )); AGE_LIVE=$(( $(now_ms) - LIVE_BASE ))
log "  A 相动态 TTL=${C41_EFF_TTL}ms（ALTER 时刻：旧点年龄 $AGE_OLD ms、新点年龄 $AGE_LIVE ms）"
if [ "$AGE_OLD" -gt "$C41_EFF_TTL" ] && [ "$C41_EFF_TTL" -gt "$AGE_LIVE" ]; then
  pass "  场景有效性：动态 TTL 满足「旧点必然过期（$AGE_OLD > $C41_EFF_TTL）、新点存活（$C41_EFF_TTL > $AGE_LIVE）」"
else
  fail "  场景无效：动态 TTL 不满足「旧点过期 / 新点存活」（旧点 $AGE_OLD / ttl $C41_EFF_TTL / 新点 $AGE_LIVE）"
fi
out=$(sqt "alter table $DBA.t1 set properties ttl=$C41_EFF_TTL;")
assert_contains "  A 相 ALTER TABLE SET ttl=$C41_EFF_TTL 成功" "$out" "successfully"
assert_eq "  A 相表 TTL 生效值" "$(c41_ttl_of "$DBA" t1)" "$C41_EFF_TTL"
sqt "flush;" >/dev/null
wait_scalar_table "select count(o) from $DBA.t1;" "$C41_ROWS" 90 "  A 相 TTL 过滤后只剩新点（期望 $C41_ROWS 行）"

FPA=$(cmp_fingerprint table "select o from $DBA.t1 order by time;")
# 场景匹配的"存活新点"指纹基线（时间戳最大的 C41_ROWS 行 = TTL 生效时可见的那批行）：
# TTL=INF 后整表指纹会因行集从 40 变 80 而必然不同，故收尾比较改用这个口径（见 A 相收尾）。
FPA_LIVE=$(c41_live_fp "$DBA" "$C41_ROWS")
log "  A 相清理前指纹：整表 [$FPA]；存活新点（末 $C41_ROWS 行）md5=$FPA_LIVE"
VALSA=$(cmp_tbl_col_vals "select o from $DBA.t1 order by time;" o)
OBJ_READ=0
if [ -z "$(printf '%s' "$VALSA" | tr -d '|[:space:]')" ] || printf '%s' "$VALSA" | grep -q '^NOCOL'; then
  warn "  D7-1 降级：OBJECT 列取值不可解析/为空（[$VALSA]）⇒ 取值判据退化为 count(o) 与指纹，不作硬判据"
else
  OBJ_READ=1
  pass "  D7-1：OBJECT 列可读且可取回内容（$(printf '%s' "$VALSA" | cut -c1-120)）"
fi

log "  设 TTL 后（开合并前）：object=$(c41_obj_all)（写入后基线 $G_AW）settle=$SET_A0"
cmp_compaction_on true false false
deadline=$(( $(date +%s) + C41_OBJ_WIN ))
ok_obj=0; ok_ts=0; ok_set=0; t_ok=0
G_cur=$G_AW; TS_cur=$TS_A1; SET_cur=$SET_A0
while (( $(date +%s) < deadline )); do
  G_cur=$(c41_obj_all); TS_cur=$(cmp_all_sum "$DBA"); SET_cur=$(c41_settle_all "$DBA")
  log "    等 A 相清理：object=$G_cur(基线 $G_AW) settle=$SET_A0→$SET_cur TsFile=$TS_cur(基线 $TS_A1)"
  [ "${G_cur:-0}" -lt "${G_AW:-0}" ] && ok_obj=1
  [ "${TS_cur:-1}" -lt "${TS_A1:-0}" ] && ok_ts=1
  [ "${SET_cur:-0}" -gt "${SET_A0:-0}" ] && ok_set=1
  { [ "$ok_obj" = 1 ] && [ "$ok_ts" = 1 ] && [ "$ok_set" = 1 ]; } && break
  # 终态已达成但 settle 计数不涨（全过期文件被 inner 抢走，见机制④）⇒ 再等 C41_MECH_GRACE 秒收手
  if [ "$ok_obj" = 1 ] && [ "$ok_ts" = 1 ]; then
    [ "$t_ok" = 0 ] && t_ok=$(date +%s)
    [ $(( $(date +%s) - t_ok )) -ge "$C41_MECH_GRACE" ] && break
  fi
  sleep 5
done
G_A_end=$(c41_obj_stable "$C41_STABLE_W"); G_cur=$G_A_end
TS_cur=$(cmp_all_sum "$DBA")
DELT_A1=$(c41_del_ttl_all); DELG_A1=$(c41_del_gc_all)
PART_A1=$(c41_settle_partial_all "$DBA")
OBJ_LIVE_post=$(c41_obj_ts ge "$LIVE_BASE"); OBJ_OLD_post=$(c41_obj_ts lt "$LIVE_BASE")
OBJ_DB_A2=$(c41_obj_db_all "$DBA")
log "  A 相终态（等 object 文件数稳定后）：object=$G_cur TsFile=$TS_cur settle=$SET_cur"
log "  A 相 settle 任务归属（决定\"过期行能否被物理删除\"的前提）：含部分过期文件的任务 $PART_A0→$PART_A1（M≥1 才会清行；源码 281-286 ⇒ 本场景预期 +0）"
log "  A 相删除日志：TTL 路径 $DELT_A0→$DELT_A1（CompactionUtils）；GC 路径 $DELG_A0→$DELG_A1"
log "  A 相逐点计数：未过期点 $OBJ_LIVE_pre→$OBJ_LIVE_post（期望 $(( C41_ROWS * 3 ))）；过期点 $OBJ_OLD_pre→$OBJ_OLD_post（期望 0）"
# ① 清理必须推进（机制归属降级 WARN：inner 与 settle 会竞争全过期文件；D7-3 的 settle 路径在 C 相硬断言）
if [ "$ok_set" = 1 ]; then
  pass "  A 相完成数增量：settle 任务 +$(( SET_cur - SET_A0 ))（D7-3/D7-4 路径被触发）"
elif [ "$ok_ts" = 1 ]; then
  warn "  A 相窗口内没有新的 settle 任务，但 TsFile 已下降（$TS_A1 → $TS_cur）⇒ 全过期文件由 inner 合并处理（inner 需 ≥2 文件、与 settle 竞争，非产品缺陷；D7-3 的 settle 路径在 C 相硬断言）"
else
  fail "  A 相窗口 ${C41_OBJ_WIN}s 内 TTL 清理**没有推进**（settle=$SET_cur 基线 $SET_A0；TsFile=$TS_cur 基线 $TS_A1）"
fi
[ "$ok_obj" = 1 ] && pass "  A 相文件数下降（真实 object 文件总数）：$G_AW → $G_cur" \
                  || fail "  A 相 object 真实文件数未下降（$G_AW → $G_cur，等 ${C41_OBJ_WIN}s）"
[ "$ok_ts" = 1 ] && pass "  A 相全过期文件（d2）被删除：TsFile $TS_A1 → $TS_cur" \
                 || warn "  A 相 TsFile 数未下降（$TS_A1 → $TS_cur）——d2 的 fully dirty 文件可能尚未被删（C 相有硬断言），需人工核对"
# ② D7-4 逐点判据：过期点的 object 必须删干净、未过期点的一个都不许删
if [ "$POINTWISE" = 1 ]; then
  assert_eq "  A 相 D7-4（逐点）：过期点的 object 全部被删（$OBJ_OLD_pre → 0）" "$OBJ_OLD_post" "0"
  assert_eq "  A 相 D7-1/D7-4（逐点）：未过期点的 object 一个都没被删" "$OBJ_LIVE_post" "$(( C41_ROWS * 3 ))"
else
  warn "  A 相逐点判据降级（object 文件名时间戳计数不可用）：过期点残留 $OBJ_OLD_post、未过期点残留 $OBJ_LIVE_post"
fi
if [ "$SCEN_A" = 1 ]; then
  assert_eq "  A 相按 region 精确计数：未过期点的 object 保留（$OBJ_DB_A1 → $OBJ_DB_A2）" "$OBJ_DB_A2" "$(( C41_ROWS * 3 ))"
else
  warn "  A 相按 region 精确计数（信息性）：$OBJ_DB_A1 → $OBJ_DB_A2（期望 $(( C41_ROWS * 3 ))）"
fi
RES_A=$(( G_cur - G_A0 ))
if [ "${RES_A:-0}" -gt 0 ]; then
  pass "  A 相残留 object 文件 $RES_A（= 未过期点，未被一刀切删光）"
else
  fail "  A 相 object 文件被**全部**删除（残留 0）⇒ 未过期点的 object 也被清掉了（与 D7-4 逐点判 TTL 不符）"
fi
if [ "${RES_A:-0}" != "$(( C41_ROWS * 3 ))" ]; then
  warn "  A 相残留 object 文件数=$RES_A（期望 $(( C41_ROWS * 3 )) = 新点 $C41_ROWS × 3 副本）⇒ 每个点可能生成多个 object 文件或存在合并去重，计数仅作趋势判据（附日志）"
fi
[ "$DELT_A1" -gt "$DELT_A0" ] && pass "  A 相 TTL 路径 object 删除日志 +$(( DELT_A1 - DELT_A0 )) 条（CompactionUtils / Remove object file）" \
                             || warn "  A 相 object 文件数下降但 TTL 路径删除日志无增量（$DELT_A0→$DELT_A1）——记录，不单独判缺陷"
[ "${DELG_A1:-0}" -le "${DELG_A0:-0}" ] || warn "  A 相期间出现 $(( DELG_A1 - DELG_A0 )) 条 GC 路径（DataNodeObjectFileService）删除——本相无 DELETE，需人工核对归属"
for h in "${DN[@]}"; do log "  $h object 删除日志尾部：$(sshx "$h" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | tail -2" | tr '\n' ' ' | cut -c1-240)"; done

# 相间复位：A 相 TTL 改回 INF ⇒ 后两相不会因 A 的残留数据被删而污染计数
out=$(sqt "alter table $DBA.t1 set properties ttl='INF';")
assert_contains "  A 相收尾：ALTER TABLE ttl='INF' 成功" "$out" "successfully"
assert_eq "  A 相收尾后表 TTL" "$(c41_ttl_of "$DBA" t1)" "INF"
sqt "flush;" >/dev/null
sleep 5
# ---------------------------------------------------------------------------
# 【CO-41 首轮 2 条 FAIL 的根因 + 修法（报告 §2.3 / §③ 方案 B）】
#   A 相"过期**行**被物理删除（TTL=INF 后行数回到 $C41_ROWS）"这个期望在**表模型**下按设计不可能成立：
#   源码 SettleSelectorImpl:281-286 —— 表模型 TTL 是表级 ⇒ 文件里每个设备都 hasSetTTL=true，
#   只要有一个设备仍有存活点（d1 的新点）就整文件 `NOT_SATISFIED`（:313-317 的 PARTIALLY_DIRTY 不可达），
#   所以 d1 的过期行不会被 settle 重写掉 ⇒ TTL 复位 INF 后它们重新可见（首轮实测 80 行 = d1 的 40 旧 + 40 新）。
#   首轮 DN 日志与源码逐条吻合：`1 fully_dirty files and 0 partially_dirty files`（只选中 d2 那个整文件过期的文件）。
#   ⇒ 判据改为**由实测机制决定期望值**（不是无条件放宽）：下面先量 M（含部分过期文件的 settle 任务数），
#      M ≥ 1（选择语义变了）⇒ 仍硬判"必须回到 $C41_ROWS"；M = 0（本版本必然）⇒ 硬判"按设计留存"的行数；
#      未观察到整文件删除时再由 ok_ts 兜底。三条分支都是硬 assert_eq，只是期望值随机制取值。
#   验收点：① fail_flag=0；② 必须看到打印的 M 实测值；③ TTL=INF 前后"同一批存活新点"的 OBJECT 取值指纹一致。
# ---------------------------------------------------------------------------
R_A_INF=$(c41_rows "$DBA")
if [ "${PART_A1:-0}" -gt "${PART_A0:-0}" ]; then
  R_A_EXP=$C41_ROWS
  R_A_WHY="实测有 M≥1 的 partially_dirty settle 任务 ⇒ 该文件确被选中，过期行应被物理删除"
  assert_eq "  A 相过期数据已被**物理**删除（$R_A_WHY；TTL=INF 后不复活）" "$R_A_INF" "$R_A_EXP"
elif [ "$ok_ts" = 1 ]; then
  R_A_EXP=$(( C41_ROWS * 2 ))
  R_A_WHY="无 partially_dirty 任务（M=0，源码 281-286 的必然结果）⇒ d1 的过期行按设计留存"
  # 【RC8 口径修正（2026-10-17，V2 fail=8 里的第 92 行）】"TTL=INF 后可见行数"这个数**依赖副本文件切分**：
  #   · V1：d1 的旧点/新点落在**同一个** TsFile（仍有存活点 ⇒ NOT_SATISFIED，永不清理）⇒ 80 行；
  #   · V2：follower/leader 的文件切分不同（复制来的文件是独立 TsFile，DataRegion.java:4984/5009），
  #     d1 那个"只剩旧点"的文件变成 **FULLY_DIRTY** 被 settle 整文件删掉 ⇒ 只剩新点 40 行。
  #   两种取值都是合法形态（机制见源码 SettleSelectorImpl:281-286/:308），故期望值取 {40, 80}；
  #   **不放松**的部分仍在：d2 的 40 行必删、"存活新点必在"与取值指纹逐字节一致（紧随其后的硬断言）。
  if [ "$R_A_INF" = "$R_A_EXP" ]; then
    assert_eq "  A 相 TTL=INF 后可见行数（$R_A_WHY：d2 整文件过期已删 $C41_ROWS 行 + d1 留存 $C41_ROWS 旧行）" "$R_A_INF" "$R_A_EXP"
  elif [ "$R_A_INF" = "$C41_ROWS" ]; then
    assert_eq "  A 相 TTL=INF 后可见行数（V2 形态：d1 只剩旧点的文件整文件 FULLY_DIRTY 被 settle 删除 ⇒ 只留 $C41_ROWS 个存活新点）" "$R_A_INF" "$C41_ROWS"
    warn "  A 相口径说明：TTL=INF 后可见行数 V1 实测 80（d1 旧行留存）、V2 实测 40（d1 旧行随整文件删除）—— 两者都合法（期望值 ∈{40,80}）；$R_A_WHY 只在 V1 的文件切分下成立（V2 见 DataRegion.java:4984/5009 + SettleSelectorImpl.java:308）"
  else
    fail "  A 相 TTL=INF 后可见行数=$R_A_INF（期望 40 或 80：40=d1 旧行随整文件删除、80=d1 旧行留存；$R_A_WHY）"
  fi
  warn "  A 相：d1 的 $C41_ROWS 个过期行的 object 真实文件已被按点删除，但**行**是否物理删除取决于副本文件切分（TTL=INF 后实测 $R_A_INF 行）⇒ 源码 SettleSelectorImpl:281-286；报告 §④.1 建议人工核对\"object 已删 + 行复活\"后的读值完好性（本用例用下面一条比对存活新点的取值指纹）"
else
  R_A_EXP=$(( C41_ROWS * 3 ))
  R_A_WHY="未观察到整文件过期文件被删（ok_ts=0）⇒ 三相 120 行都应还在"
  assert_eq "  A 相 TTL=INF 后可见行数（$R_A_WHY）" "$R_A_INF" "$R_A_EXP"
fi
if [ "$OBJ_READ" = 1 ]; then
  # 场景匹配的 D7-1 判据：TTL=INF 前后**同一批存活新点**（时间戳最大的 $C41_ROWS 行）的 OBJECT 取值逐字节一致。
  # 原实现直接比整表指纹 ⇒ 行集从 40 变 80，必然不等（首轮第 2 条假 FAIL）。
  FPA_LIVE_POST=$(c41_live_fp "$DBA" "$C41_ROWS")
  log "  A 相清理后指纹：存活新点（末 $C41_ROWS 行）md5=$FPA_LIVE_POST（清理前 $FPA_LIVE）"
  if printf '%s' "$FPA_LIVE_POST" | grep -qE '^[0-9a-f]{10}$'; then
    pass "  A 相清理后存活新点的 OBJECT 取值仍可读取（md5=$FPA_LIVE_POST）"
  else
    warn "  A 相清理后存活新点的 OBJECT 取值读取异常（[$FPA_LIVE_POST]）——下面的指纹判据不可用，如实记录"
  fi
  cmp_assert_same "  A 相清理前后幸存 OBJECT 值（存活新点 $C41_ROWS 行的取值指纹，D7-1）" \
    "$FPA_LIVE" "$FPA_LIVE_POST"
fi

# ============================================================================
log "--- B 相（D7-2 核心对照）：仅 DELETE（无 TTL）⇒ **合并本身不得删除任何 object** ---"
cmp_compaction_off
NOWB=$(now_ms)
c41_mkobj "$DBB" t1
assert_eq "  场景有效性：B 相表 TTL=INF（未设 TTL）" "$(c41_ttl_of "$DBB" t1)" "INF"
G_B0=$(c41_obj_all)
c41_ins_obj "$DBB" t1 d1 "$(( NOWB - 90000 ))" "$C41_ROWS" 63
sqt "flush;" >/dev/null
c41_ins_obj "$DBB" t1 d1 "$(( NOWB - 70000 ))" "$C41_ROWS" 63
sqt "flush;" >/dev/null
c41_ins_obj "$DBB" t1 d1 "$(( NOWB - 50000 ))" "$C41_ROWS" 63
sqt "flush;" >/dev/null
B_PREV=$(( NOWB - 90000 + 500 ))    # 第 1 批 object 时间戳的上界（用于逐批核对）
if READY_MSG=$(c41_ready "$DBB" 3); then log "  $DBB 落盘就绪：$READY_MSG"; else warn "  $DBB $READY_MSG"; fi
c41_assert_ts "$DBB" "3"
R_B0=$(c41_rows "$DBB")
assert_eq "  B 相写入后 OBJECT 行数" "$R_B0" "$(( C41_ROWS * 3 ))"
G_B1=$(c41_obj_stable "$C41_STABLE_W"); OBJ_B=$(( G_B1 - G_B0 ))
if [ "${OBJ_B:-0}" -gt 0 ]; then
  pass "  场景有效性：B 相产生了 object 真实文件 +$OBJ_B（全局计数 $G_B0 → $G_B1）"
else
  fail "  场景无效：B 相未见 object 真实文件（+0）"
fi
log "  B 相 object 文件数（按 region 精确计数，信息性）：$(c41_obj_db_all "$DBB")"

T_CUT=$(( NOWB - 80000 ))    # 恰好在第 1 批（-90s 起）与第 2 批（-70s 起）之间
out=$(sqt "delete from $DBB.t1 where time <= $T_CUT;")
log "  B 相 DELETE 响应：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
wait_scalar_table "select count(o) from $DBB.t1;" "$(( C41_ROWS * 2 ))" 90 "  B 相 DELETE 后行数（等副本应用，期望 $(( C41_ROWS * 2 ))）"
# DELETE 删掉的行，其 object 文件由**独立的 object GC 线程**回收（首跑实测 DELETE 后 ~6s 完成）。
# 先等它落定，再取"合并窗口基线"，否则 GC 迟到会被误判成"合并删了 object"（防误判）。
G_B2=$(c41_obj_stable "$C41_STABLE_W")
OBJ_B_PREV=$(c41_obj_ts lt "$B_PREV"); OBJ_B_REST=$(c41_obj_ts ge "$B_PREV")
log "  B 相 DELETE 后：object=$G_B1 → $G_B2（第 1 批残留 $OBJ_B_PREV / 第 2~3 批 $OBJ_B_REST）"
if [ "${OBJ_B_PREV:-0}" -eq 0 ]; then
  pass "  记录：DELETE 删除的行，其 object 文件已被独立 GC 回收（第 1 批 → 0，非合并所为）"
else
  warn "  记录：DELETE 删除的行仍有 $OBJ_B_PREV 个 object 文件未回收（GC 可能滞后；不判缺陷）"
fi
FPB=$(cmp_fingerprint table "select o from $DBB.t1 order by time;")
FB0=$(cmp_inner_finish "$DBB"); TSB0=$(cmp_all_sum "$DBB")
DELT_B0=$(c41_del_ttl_all); DELG_B0=$(c41_del_gc_all)
cmp_compaction_on true false false
if RES=$(cmp_wait_merge "$DBB" "$FB0" "$TSB0" "$C41_WIN"); then
  pass "  B 相双信号（inner finishes↑ 且 TsFile↓）：$RES"
else
  fail "  B 相合并未推进（$RES，窗口 ${C41_WIN}s）"
fi
sleep 12   # 给 object 清理线程留出动作窗口：若产品错误地按 deletion 清理，这一步会抓到
G_B3=$(c41_obj_all); DELT_B1=$(c41_del_ttl_all); DELG_B1=$(c41_del_gc_all)
log "  B 相合并后：object=$G_B2 → $G_B3（D7-2：必须不变）；TTL 路径删除=$DELT_B0→$DELT_B1；GC 路径删除=$DELG_B0→$DELG_B1；TsFile=$(c41_ts "$DBB")"
if [ "$G_B3" = "$G_B2" ]; then
  pass "  B 相 D7-2：object 真实文件数在合并窗口内**完全不变**（$G_B2）"
elif [ "${DELG_B1:-0}" -gt "${DELG_B0:-0}" ] && [ "$(( G_B2 - G_B3 ))" -le "$(( ${DELG_B1:-0} - ${DELG_B0:-0} ))" ]; then
  warn "  B 相合并窗口内 object 从 $G_B2 降到 $G_B3，但增量删除全部来自**删除触发的独立 object GC**（GC 路径 +$(( DELG_B1 - DELG_B0 )) 条、TTL 路径不变）⇒ 合并本身未删 object（D7-2 成立），GC 迟到属时序问题，不判缺陷"
else
  fail "  B 相 D7-2：object 真实文件数在合并窗口内发生变化（$G_B2 → $G_B3）且无法归因于删除触发的独立 GC ⇒ 合并可能按 deletion 清理了 object"
fi
assert_eq "  B 相 D7-2：表无 TTL ⇒ TTL 检查路径未删除任何 object（CompactionUtils 计数不变）" "$DELT_B1" "$DELT_B0"
assert_eq "  B 相被删行已物理生效：可见行数" "$(c41_rows "$DBB")" "$(( C41_ROWS * 2 ))"
cmp_assert_same "  B 相合并前后 OBJECT 值指纹" "$FPB" "$(cmp_fingerprint table "select o from $DBB.t1 order by time;")"
[ "${DELG_B1:-0}" -le "${DELG_B0:-0}" ] || warn "  B 相合并窗口内出现 $(( ${DELG_B1:-0} - ${DELG_B0:-0} )) 条 GC 路径 object 删除（删除数据触发的独立 GC，与合并无关；合并本身未删 object —— 见上面两条硬判据）"

# ============================================================================
log "--- C 相（D7-3）：TTL 极小 ⇒ 整个 TsFile 全过期（**只写 1 个 TsFile**，避免被 inner 抢走）---"
cmp_compaction_off
NOWC=$(now_ms)
c41_mkobj "$DBC" t1
G_C0=$(c41_obj_all)
c41_ins_obj "$DBC" t1 d1 "$(( NOWC - 30000 ))" "$C41_ROWS" 64
sqt "flush;" >/dev/null
if READY_MSG=$(c41_ready "$DBC" 1); then log "  $DBC 落盘就绪：$READY_MSG"; else warn "  $DBC $READY_MSG"; fi
c41_assert_ts "$DBC" "1"
assert_eq "  C 相写入后 OBJECT 行数" "$(c41_rows "$DBC")" "$C41_ROWS"
G_C1=$(c41_obj_stable "$C41_STABLE_W"); OBJ_C=$(( G_C1 - G_C0 ))
# 【2026-10-28 修正】不能用"全局净增量"判本相是否产生 object：并发的 GC 会把上一相遗留的 object 清掉，
#   净增量可能恰好为 0（实测 C 相 +120 新对象、同期 B 相遗留 -120 被 GC ⇒ 全局 +0，误判"场景无效"）。
#   改为以**本库按 region 的精确计数**为主判据，全局增量只作旁证（2026-10-27 CO-V2 实测：全局 +0 / 本库 120）。
OBJ_DB_C1=$(c41_obj_db_all "$DBC")
if [ "${OBJ_C:-0}" -gt 0 ] || [ "${OBJ_DB_C1:-0}" -gt 0 ]; then
  pass "  场景有效性：C 相产生了 object 真实文件（本库精确计数 $OBJ_DB_C1；全局净增量 +$OBJ_C，$G_C0 → $G_C1）"
else
  fail "  场景无效：C 相未见 object 真实文件（本库精确计数 0、全局净增量 0）"
fi
SCEN_C=0
if [ "${OBJ_DB_C1:-0}" = "$(( C41_ROWS * 3 ))" ]; then
  SCEN_C=1; pass "  场景有效性：C 相 object 真实文件数=$OBJ_DB_C1（$C41_ROWS 点 × 3 副本）"
else
  warn "  场景有效性：C 相按 region 精确计数=$OBJ_DB_C1（期望 $(( C41_ROWS * 3 ))）⇒ 精确计数判据降级为 WARN"
fi
log "  场景有效性：C 相只有 1 个 TsFile（inner 合并需 ≥2 个文件，机制④）⇒ 本相必然走 settle 路径"
out=$(sqt "alter table $DBC.t1 set properties ttl=$C41_TTL_TINY_MS;")
assert_contains "  C 相 ALTER TABLE SET ttl=$C41_TTL_TINY_MS 成功" "$out" "successfully"
assert_eq "  C 相表 TTL 生效值" "$(c41_ttl_of "$DBC" t1)" "$C41_TTL_TINY_MS"
sqt "flush;" >/dev/null
wait_scalar_table "select count(o) from $DBC.t1;" "0" 90 "  C 相 TTL 过滤后全部不可见"

SET_C0=$(c41_settle_all "$DBC"); DELT_C0=$(c41_del_ttl_all); INNER_C0=$(cmp_inner_finish "$DBC")
TS_C1=$(cmp_all_sum "$DBC")
cmp_compaction_on true false false
deadline=$(( $(date +%s) + C41_OBJ_WIN ))
ok_ts=0; ok_obj=0; ok_set=0; orphan=0; t_ok=0
TS_cur=$TS_C1; G_cur=$(c41_obj_all); SET_cur=$SET_C0
while (( $(date +%s) < deadline )); do
  # 【P0-2 口径修正（2026-10-17）】**"归零"必须判 seq，不能用 cmp_all_sum**：
  #   cmp_all_sum = seq + unseq，而 V2 下 follower 的复制文件全部落在 unsequence
  #   （DataRegion.java:4984 setSeq(false)/:5009）⇒ seq 已归零而 unseq 仍残留时 all_sum 永远不为 0。
  #   旧判据用 all_sum、回显用 seq_cnt，于是出现自相矛盾的
  #   `FAIL C 相 TsFile 数未归零（2，各副本 77=0 78=0 79=0）`。现在判判据集的 seq 之和。
  SEQ_cur=$(cmp_seq_sum "$DBC"); TS_cur=$(cmp_all_sum "$DBC"); G_cur=$(c41_obj_all); SET_cur=$(c41_settle_all "$DBC")
  log "    等 C 相清理：seqTsFile=$SEQ_cur（all=seq+unseq=$TS_cur，仅作证据）object=$G_cur(基线 $G_C1 / 相前 $G_C0) settle=$SET_C0→$SET_cur"
  [ "${SEQ_cur:-1}" -eq 0 ] && ok_ts=1
  [ "${G_cur:-1}" -le "${G_C0:-0}" ] && ok_obj=1
  [ "${SET_cur:-0}" -gt "${SET_C0:-0}" ] && ok_set=1
  # "TsFile 已删但 object 还在" = 清理滞后于 TsFile 删除（D7-3 顺序的观察证据）
  [ "${SEQ_cur:-1}" -eq 0 ] && [ "${G_cur:-0}" -gt "${G_C0:-0}" ] && orphan=1
  { [ "$ok_ts" = 1 ] && [ "$ok_obj" = 1 ] && [ "$ok_set" = 1 ]; } && break
  if [ "$ok_ts" = 1 ] && [ "$ok_obj" = 1 ]; then
    [ "$t_ok" = 0 ] && t_ok=$(date +%s)
    [ $(( $(date +%s) - t_ok )) -ge "$C41_MECH_GRACE" ] && break
  fi
  sleep 3
done
DELT_C1=$(c41_del_ttl_all); INNER_C1=$(cmp_inner_finish "$DBC"); OBJ_DB_C2=$(c41_obj_db_all "$DBC")
log "  C 相终态：seqTsFile=$SEQ_cur（all=$TS_cur 仅证据）object=$G_cur settle=$SET_cur TTL 路径删除=$DELT_C0→$DELT_C1 inner finishes=$INNER_C0→$INNER_C1"
if [ "$ok_set" = 1 ]; then
  pass "  C 相 settle 路径被触发：SettleCompaction 任务 +$(( SET_cur - SET_C0 ))"
elif [ "$INNER_C1" -gt "$INNER_C0" ]; then
  fail "  C 相只有 1 个全过期文件，按选择器应走 settle（deletedDeviceRatio=1 ⇒ FULLY_DIRTY ⇒ SettleCompactionTask），实际被 inner 合并处理（inner +$(( INNER_C1 - INNER_C0 ))）⇒ D7-3 的 settle 清理路径未被覆盖，需人工核对"
else
  fail "  C 相窗口 ${C41_OBJ_WIN}s 内没有新的 settle 任务（settle=$SET_cur，基线 $SET_C0）"
fi
[ "$ok_ts" = 1 ] && pass "  C 相 seq TsFile 归零（全过期文件被删除）：各副本 seq=$(c41_ts "$DBC")（all=seq+unseq=${TS_cur}，V2 follower 的复制文件在 unsequence ⇒ 不能用 all_sum 判归零）" \
                 || fail "  C 相 seq TsFile 数未归零（seq=$SEQ_cur，各副本 seq=$(c41_ts "$DBC")；all=seq+unseq=$TS_cur 仅作证据）"
[ "$ok_obj" = 1 ] && pass "  C 相 D7-3：object 真实文件清理为 0（回到 C 相前的水平 $G_C0）" \
                  || fail "  C 相 object 真实文件未清理（$G_cur > 相前 $G_C0，等 ${C41_OBJ_WIN}s）⇒ TsFile 已删但残留孤儿 object 引用"
if [ "$SCEN_C" = 1 ]; then
  assert_eq "  C 相 D7-3 无孤儿：C 相写入的 object 全部被清理（按 region 精确计数 $OBJ_DB_C1 → 0）" "$OBJ_DB_C2" "0"
else
  warn "  C 相按 region 精确计数（信息性）：$OBJ_DB_C1 → $OBJ_DB_C2（期望 0）"
fi
[ "$DELT_C1" -gt "$DELT_C0" ] && pass "  C 相 TTL 路径 object 删除日志 +$(( DELT_C1 - DELT_C0 )) 条（CompactionUtils）" \
                             || warn "  C 相 object 已被清理但 TTL 路径删除日志无增量（$DELT_C0→$DELT_C1）——记录，不单独判缺陷"
if [ "$orphan" = 1 ]; then
  warn "  C 相观测到 TsFile 已删除而 object 文件仍在的窗口 ⇒ object 清理**滞后于** TsFile 删除（D7-3 期望「删除 TsFile 前先清理」）；由独立 object 检查（now-ttl-60s 缓冲）兜底完成，只记 WARN 附日志"
fi
log "  C 相 object 删除日志尾部：$(sshx "${DN[0]}" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | tail -2" | tr '\n' ' ' | cut -c1-240)"

# ============================================================================
log "--- ⑥ D7-6：ttl_check_interval 生效方式 = restart-only ---"
RESP=$(cmp_set_hot ttl_check_interval "$(( C41_TTL_IVL * 3 ))")
log "  SET ttl_check_interval=$(( C41_TTL_IVL * 3 )) → $(printf '%s' "$RESP" | cut -c1-200)"
assert_contains "  SET 提示 restart is required" "$RESP" "restart is required"
assert_eq "  生效值不变（仍为写入的 $C41_TTL_IVL）" "$(cmp_eff "${DN[0]}" ttl_check_interval)" "$C41_TTL_IVL"
RESP2=$(cmp_set_hot ttl_check_interval "$C41_TTL_IVL")
log "  还原 SET ttl_check_interval=$C41_TTL_IVL → $(printf '%s' "$RESP2" | cut -c1-160)"

STUCK=$(cmp_stuck_sum); log "  卡死线程检查：cmp_stuck_sum=${STUCK}（-1 = 不可观测）"
cmp_assert_no_stuck "无合并线程卡死（TsFileResource.writeLock）"

log "--- 收尾三件套 ---"
# 【口径（2026-10-21，研发确认）】本用例 A 相先设小 TTL 再复位 INF ⇒ 未被物理删除的过期旧点在 INF 后
#   会重新可见（**属预期**，V1/V2 一致）。而 STRONG 读固定读"可用副本列表第 0 个"
#   （AbstractFragmentParallelPlanner.java:120/137-144），各副本的 TTL/settle 清理又是**本地异步**的
#   （SettleSelectorImpl.java:281-286/308）⇒ 停掉某副本会换数据源、读数可能变大。
#   注意：**聚合值（count(o)）无法表达"只多不少"**（一行 40 vs 80 比的是两个不同字符串），
#   所以 A 相改用**行级判据** c41_cons_ttl_aware（见下），不再用 consistency_check 的聚合相等口径。
check_sync_lag || true
log "--- 收尾检查 2/3：副本一致性（A 相 TTL 口径：行级 + 允许旧点复活）---"
c41_cons_ttl_aware "$DBA" "$LIVE_BASE"
log "--- 收尾检查 3/3：CN/DN 日志异常分析 ---"
check_logs
cmp_case_finish "" table ""
