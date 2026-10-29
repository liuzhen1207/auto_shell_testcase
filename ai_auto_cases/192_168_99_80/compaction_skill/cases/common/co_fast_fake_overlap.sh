#!/bin/bash
# ============================================================================
# CO-36 · FastCompaction 直搬路径：「假 overlap」page 直刷 + ALL_DELETED 跳过
#          （D5-1 / D5-2 / D5-3；官方 FC-02-3）
#
# 源码依据（RC6 = 7ae8713ecb，本地源码树逐行可对照）：
#   · `execute/performer/impl/FastCompactionPerformer.java` = `cross_performer`/`inner_*_performer` 取值 `fast` 的实现
#     （合法取值：`cross_performer` ∈ {read_point, fast}、`inner_seq_performer` ∈ {read_chunk, fast}、
#      `inner_unseq_performer` ∈ {read_point, fast}；见 docs/CONF_PARAMS.md 的「模板给出的合法取值」表）；
#   · `execute/utils/executor/fast/SeriesCompactionExecutor.java`：
#       L140-162 `compactChunks()`：chunk 与下一个 chunk **不重叠** ⇒ `chunkNoneOverlap++` + **直接 flush**；
#       L215-245 `compactPages()`：page 的 `ALL_DELETED` ⇒ `checkShouldRemoveFile()` 后 `continue`（**不解开、不写进产物**，D5-3）；
#       L319-343 `checkAndCompactOverlapPage()`：`isNextPageOverlap = 当前点 <= 下一页 endTime
#                || 下一页 endTime >= nextPageStartTime || 下一页 endTime >= nextChunkStartTime`；
#                **三条都不成立 ⇒ 该 page 落在另一 page 的"空隙"里 ⇒ `pageFakeOverlap++` + 直接刷（D5-2）**；
#   · `execute/task/CrossSpaceCompactionTask.java:443-450 createSummary()`：
#       `performer instanceof FastCompactionPerformer` ⇒ summary = `FastCompactionTaskSummary`（否则普通 `CompactionTaskSummary`）；
#   · `FastCompactionTaskSummary#toString()`：`… PAGE_NONE_OVERLAP num is %d, … PAGE_FAKE_OVERLAP num is %d.`
#     而任务完成的日志行**把 summary 作为最后一个占位符打印**
#     （`{}-{} [Compaction] CrossSpaceCompaction task finishes successfully, time cost is {} s, compaction speed is {} MB/s, {}`）
#     ⇒ **`PAGE_FAKE_OVERLAP num is N` 是产品自己打出来的 page 级直搬证据**（本用例 ⑤ 的硬判据；
#        read_chunk / read_point 路径打印的是普通 `…CompactionTaskSummary@hash`，**没有**这些计数器 ⇒ 顺带成为 performer 切换的证据）。
#
# 「假 overlap」构造（D5-2 的原文例子）：
#   step1 写 1 批 seq，**只有区间两端的点**（t0、t0+SPAN）⇒ 该文件的 page 覆盖 [t0, t0+SPAN]；
#   step2 写更早的 unseq 落在**内部空隙** [t0+100, t0+200] ⇒ 文件级"区间重叠"（会被 cross 选中），
#         但 page 级没有真正重叠的点 ⇒ fast 路径命中 `pageFakeOverlap`（直刷）；
#   step3 写 [t0+300, t0+900] 后 `DELETE` 掉 ⇒ 该 unseq 文件整文件 ALL_DELETED（D5-3）。
#   **负向对照**（证明 `PAGE_FAKE_OVERLAP` 不是恒 >0）：seq 端点改成 {0, 150, 1000}，unseq 仍落在 [100,200]
#   （跳过 150 避免同时间戳），此时"当前点(150) <= 下一页 endTime(200)" 成立 ⇒ 真 overlap ⇒ `PAGE_FAKE_OVERLAP = 0`。
#
# 五相：
#   1) `root.cofk`：假 overlap + ALL_DELETED，`cross_performer=fast`
#      ① 双信号（cross finishes ↑、unseq 归零、TsFile ↓）；② 指纹不变（含被删段不得复活）；
#      ③ 空隙段行数保留、被删段 0 行；④ 终态字节 < 源字节（ALL_DELETED 被跳过，D5-3）；
#      ⑤ **`PAGE_FAKE_OVERLAP ≥ 1`**（D5-2 的 page 级直搬证据，产品日志直接可见）。
#   2) `root.cofkd`(fast) 与 `root.cofkm`(read_point)：同一「假 overlap（无删除）」构造
#      ⑥ **直搬体积（D5-1）**：fast 相终态字节 ≥ 源字节 × 0.9；若两相字节完全相同（无可观测体积差异）
#         则按 §5 防误判**只记录 + WARN**；但 fast 相的 `PAGE_FAKE_OVERLAP ≥ 1` 与 read_point 相**没有**这些计数器，
#         仍是 performer 切换的硬证据。
#   3) `root.cofkt`：真 overlap（无删除，fast）⇒ **`PAGE_FAKE_OVERLAP = 0`**（⑤ 的负向对照）+ 双信号 + 指纹。
#   4) `root.cofku`：`inner_unseq_performer=fast`，2 个互相重叠的 unseq 文件 ⇒ 生效值 + 双信号 + 指纹 + fast 摘要存在。
#   5) `root.cofki`：`inner_seq_performer=fast`，2 个**不重叠** seq 文件 ⇒ 生效值 + 双信号 + 指纹 +
#      `CHUNK_NONE_OVERLAP`（D5-1 的 chunk 级直搬）；若只有 `CHUNK_NONE_OVERLAP_BUT_DESERIALIZE`
#      （源码 L178-181 说明"未封口 chunk 太小 / chunk.endTime > file.endTime 时退回解序列化"）则**记录 + WARN**，不判缺陷。
#   全部相：`cmp_fp_tree` 不变、`cmp_stuck_sum=0`、收尾三件套。
#
# ⚠️ 仍未做（诚实标注）：产物 page 与源 page 的**逐字节比对**需要脚本自带 TsFile 工具（读 page offset/length），
#    本用例**没有**该工具 ⇒ 只做到"产品自报 page 级直搬计数 + 文件级字节/名字记录"，
#    规格 §4.2 CO-36 ⑤ 的"逐字节"部分仍未覆盖（已在日志里 WARN 标注）。
#
# ---------------------------------------------------------------------------
# 【场景修复（2026-10-17；报告 _scratch/RC8_V2_DIVERGENCE_TRIAGE.md §3.7 / §④ P3）】
#   RC8 两轮（V1 FAIL 4823s f20 / V2 FAIL 5243s f19）的失败点几乎逐条相同 ⇒ **与共识协议无关**，
#   根因是**场景根本没造出来**：`co36_ins` 把 INSERT 的响应 `>/dev/null 2>&1` 整段丢掉，
#   101 点的"空隙批"实测 **0 行**（`总=2 空隙=0`），于是后面 17 条判据全部建立在空场景上
#   （`TsFile 3→3`、`PAGE_FAKE_OVERLAP=0`、字节数相等等都是它的下游）。
#   本轮的修法（先修场景，再谈快慢路径）：
#     ① `co36_ins` 检查每次 INSERT 的返回，失败**回显原始响应**（含错误码/文案）并计数；
#     ② `co36_seg` 打印"单条多值 INSERT 的元组数 + 语句字节数"（供定位"101 元组为何被拒"）；
#     ③ **场景有效性硬闸**：空隙批/待删批/被删段的行数必须真的对得上，否则只留**一条**
#        「场景无效」FAIL 并**跳过后续相位的判据**（不再让 17 条下游断言全部误判）。
#   ✅ 已定性（2026-10-20）：`cross_performer` 的合法取值只有 **{read_point, fast}**
#      （`CrossCompactionPerformer.java:31-46`：`READ_POINT`/`FAST` 两个枚举名，其它值抛
#      `IllegalCompactionPerformerException`）；`read_chunk` 是 **`inner_seq_performer`/`inner_unseq_performer`
#      的取值**，本用例早期把两者混用了 —— 那不是产品问题，也不存在"配置未生效"的缺陷。
#      已把 2B 相的对照 performer 改成 **`read_point`**（此前 RC8 两轮假 FAIL 都源于这个错名）。
#      `read_point` 相不会打印 fast 专有的 `PAGE_FAKE_OVERLAP` 计数器，这一点仍是"performer 切换可观测"的证据。
# ---------------------------------------------------------------------------
# 规模/参数集中在文件顶部变量，可用 CO36_* 覆盖。
# 用法： bash co_fast_fake_overlap.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_fast_fake_overlap_${DATA_CONSENSUS}"

DBF=root.cofk           # 1) 假 overlap + ALL_DELETED（cross, fast）
DBD=root.cofkd          # 2A) 假 overlap（无删除）cross, fast
DBM=root.cofkm          # 2B) 同构造 cross, read_point（对照：没有 fast 计数器）
DBT=root.cofkt          # 3) 真 overlap（无删除）cross, fast —— PAGE_FAKE_OVERLAP 的负向对照
DBU=root.cofku          # 4) inner unseq, fast
DBI=root.cofki          # 5) inner seq, fast
SPAN="${CO36_SPAN:-1000}"                 # 假 overlap 的 seq 区间长度（ms）
HOLE_N="${CO36_HOLE_N:-101}"              # 空隙段点数（[t0+100, t0+100+HOLE_N-1]）
DEL_N="${CO36_DEL_N:-601}"                # 被整段 DELETE 的点数（[t0+300, t0+300+DEL_N-1]）
BIG_SPAN="${CO36_BIG_SPAN:-100000}"       # 2) 直搬体积相的 seq 区间长度（放大让"体积"由数据体主导）
BIG_HOLE_N="${CO36_BIG_HOLE_N:-1001}"     # 2) 直搬体积相的空隙点数
INNER_N="${CO36_INNER_N:-200}"            # 4)/5) 每批点数
UNSEQ_N="${CO36_UNSEQ_N:-200}"            # 4) 每批点数
WIN_CROSS="${CO36_WIN_CROSS:-300}"        # 等 cross 完成的窗口
WIN_INNER="${CO36_WIN_INNER:-180}"        # 等 inner 完成的窗口
MOVE_RATIO_MIN="${CO36_MOVE_RATIO_MIN:-90}" # D5-1：终态字节 / 源字节 的下限（百分数）

# ---------------------------------------------------------------- 构造工具
# 建库 + 3 条序列（INT64 / DOUBLE / TEXT）
co36_mkdb(){ local db=$1
  sq "create database $db;" >/dev/null 2>&1
  sq "create timeseries $db.d1.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1
  sq "create timeseries $db.d1.s2 with datatype=DOUBLE, encoding=GORILLA, compression=SNAPPY;" >/dev/null 2>&1
  sq "create timeseries $db.d1.s3 with datatype=TEXT, encoding=PLAIN, compression=SNAPPY;" >/dev/null 2>&1
  sq "flush;" >/dev/null 2>&1; }
# 写一段点 [base+from, base+from+n-1]（一条多值 INSERT；skip_off >=0 时跳过该偏移，用于真 overlap 相）
co36_seg(){ local db=$1 base=$2 from=$3 n=$4 skip_off=${5:--1} k ts vals="" stmt ntuple=0
  for (( k=0; k<n; k++ )); do
    [ "$k" = "$skip_off" ] && continue
    ts=$(( base + from + k ))
    vals="$vals($ts,$(( k + 1 )),$(( k + 1 )).5,'v$(( k + 1 ))'),"
    ntuple=$(( ntuple + 1 ))
  done
  [ -n "$vals" ] || return 0
  stmt="insert into $db.d1(time,s1,s2,s3) values ${vals%,};"
  # 诊断"101 元组为何被拒"：把语句规模打进日志（同一批被拒时对照 CLI 的原始响应）
  log "    [$db] 单条多值 INSERT：$ntuple 个元组、语句 ${#stmt} 字节、时间区间 [$(( base + from )), $(( base + from + n - 1 ))]、跳过偏移=$skip_off"
  co36_ins "$stmt"
  sq "flush;" >/dev/null 2>&1; }
# INSERT 包装：**检查返回**（旧实现 `sq "$1" >/dev/null 2>&1` 把响应整段丢掉 ⇒ 空隙批 101 点
#   实际 0 行也无人发现，后面 17 条判据全部建在空场景上）。失败时回显原始响应（含错误码/文案）并计数。
C36_INS_ERR=0
co36_ins(){ local out
  out=$(sq "$1" 2>&1)
  if printf '%s' "$out" | grep -q 'successfully'; then
    return 0
  fi
  C36_INS_ERR=$(( C36_INS_ERR + 1 ))
  fail "  INSERT 未成功（第 ${C36_INS_ERR} 次）：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)"
  printf '%s\n' "$out" | sed 's/^/    ins| /' >>"$OUT"
  printf '%s\n' "    语句前 300 字节：$(printf '%s' "$1" | cut -c1-300)" >>"$OUT"
  return 1; }
# 写"只有区间两端的点"（2 个点：t0、t0+span）
co36_endpoints(){ local db=$1 base=$2 span=$3
  co36_ins "insert into $db.d1(time,s1,s2,s3) values ($(( base + 0 )),10,10.5,'p0'),($(( base + span )),20,20.5,'p1');"
  sq "flush;" >/dev/null 2>&1; }
# 写 3 个点：t0、t0+150、t0+span（真 overlap 相要用中间的 150 制造"当前点 <= 下一页 endTime"）
co36_endpoints3(){ local db=$1 base=$2 span=$3
  co36_ins "insert into $db.d1(time,s1,s2,s3) values ($(( base + 0 )),10,10.5,'p0'),($(( base + 150 )),15,15.5,'pm'),($(( base + span )),20,20.5,'p1');"
  sq "flush;" >/dev/null 2>&1; }
# 某设备的可见行数（树模型具体设备路径上的聚合会被忽略 ⇒ 用原始查询数行）
co36_rows(){ local n; n=$(sq "select s1 from $1.d1 order by time;" 2>/dev/null | table_rows | wc -l | tr -dc '0-9'); printf '%s\n' "${n:-0}"; }
co36_rows_range(){ local n; n=$(sq "select s1 from $1.d1 where time>=$2 and time<=$3;" 2>/dev/null | table_rows | wc -l | tr -dc '0-9'); printf '%s\n' "${n:-0}"; }
# 各副本 seq/unseq 计数的去重串（形如 "1/2 "）
co36_su_uni(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^[0-9]+:' | cut -d: -f2 | sort -u | tr '\n' ' '; }
# 该库每个 TsFile 的 "字节 名字"（直搬/重写的间接证据）
co36_files(){ local db=$1 h
  for h in "${DN[@]}"; do sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%s %f\n' 2>/dev/null | sort -k2" 2>/dev/null; done; }
# 终态字节 / 源字节 的百分比（整数）
co36_ratio(){ awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 <= 0) { print 0 } else { printf "%d", a*100/b } }'; }
# 生效值断言（只对本用例自己写进 conf 的键断言）
co36_eff(){ assert_eq "  生效值 $1" "$(cmp_eff "${DN[0]}" "$1")" "$2"; }
# fast 路径自报计数器（所有 DN 上该库的 "task finishes successfully" 行里 <field> num is N 之和；
# `cmp_log_files` 同时含 compaction/all 两个日志 ⇒ 绝对条数按 2 倍记，判据只看 ≥1 / =0）
co36_summary_field(){ local db=$1 field=$2 h tot=0 v
  for h in "${DN[@]}"; do
    v=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF 'task finishes successfully' | grep -E '(^|[- ])(root\.)?$db-[0-9]+' | grep -oE '$field num is [0-9]+' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
    tot=$(( tot + ${v:-0} ))
  done
  printf '%s\n' "$tot"; }
# 该库的"任务完成"原始日志行（证据；fast 相末尾应当出现 … PAGE_FAKE_OVERLAP num is N.）
co36_finish_lines(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF 'task finishes successfully' | grep -E '(^|[- ])(root\.)?$db-[0-9]+'" 2>/dev/null | tail -2
  done; }
# 等 DELETE 的 mods 落盘（纯函数：只回显 mods 计数）
co36_wait_mods(){ local db=$1 min=$2 win=$3 dl m
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    m=$(cmp_mods_sum "$db")
    if [ "${m:-0}" -ge "$min" ]; then printf '%s\n' "${m:-0}"; return 0; fi
    sq "flush;" >/dev/null 2>&1
    sleep 5
  done
  printf '%s\n' "${m:-0}"
  return 1; }
# 等 cross 完成（纯函数：unseq 归零 + finishes 增加；回显 "finishes|unseq"）
co36_wait_cross(){ local db=$1 fin0=$2 win=$3 dl f u
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    f=$(cmp_cross_finish "$db"); u=$(cmp_unseq_sum "$db")
    if [ "${f:-0}" -gt "${fin0:-0}" ] && [ "${u:-0}" = 0 ]; then printf '%s|%s\n' "$f" "$u"; return 0; fi
    sleep 6
  done
  printf '%s|%s\n' "${f:-0}" "${u:-0}"
  return 1; }
# 等 inner 完成（finishes 增加 且 TsFile 数下降；回显 finishes）
co36_wait_inner(){ local db=$1 fin0=$2 sum0=$3 kind=$4 win=$5 dl f s
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    case "$kind" in
      unseq) f=$(cmp_unseq_inner_finish "$db") ;;
      *)     f=$(cmp_seq_inner_finish "$db") ;;
    esac
    s=$(cmp_all_sum "$db")
    if [ "${f:-0}" -gt "${fin0:-0}" ] && [ "${s:-0}" -lt "${sum0:-0}" ]; then printf '%s\n' "$f"; return 0; fi
    sleep 6
  done
  printf '%s\n' "${f:-0}"
  return 1; }

# 假 overlap 场景构件：<db> <tag> <base> <span> <hole_n> <with_delete|no_delete>
co36_fake_scene(){ local db=$1 tag=$2 base=$3 span=$4 hole=$5 del=$6 per
  cmp_compaction_off
  co36_mkdb "$db"
  co36_endpoints "$db" "$base" "$span"
  cmp_wait_close "$db" 1 120 >/dev/null || warn "  [$tag] seq 端点批 close 未达 1"
  cmp_wait_lay "$db" "1/0/0/0" 150 >/dev/null || warn "  [$tag] 布局=$(cmp_lay "$db")（期望 1/0/0/0）"
  co36_seg "$db" "$base" 100 "$hole"
  cmp_wait_close "$db" 2 120 >/dev/null || warn "  [$tag] 空隙批 close 未达 2"
  if [ "$del" = with_delete ]; then
    co36_seg "$db" "$base" 300 "$DEL_N"
    cmp_wait_close "$db" 3 120 >/dev/null || warn "  [$tag] 待删批 close 未达 3"
    co36_ins "delete from $db.d1.** where time>=$(( base + 300 )) and time<=$(( base + 300 + DEL_N - 1 ));"
    sq "flush;" >/dev/null 2>&1
    co36_wait_mods "$db" 3 90 >/dev/null || warn "  [$tag] DELETE 的 mods 90s 内未达 3（$(cmp_mods_sum "$db")）"
  fi
  cmp_wait_su "$db" "1/$([ "$del" = with_delete ] && echo 2 || echo 1)" 150 >/dev/null \
    || warn "  [$tag] seq/unseq=$(cmp_su "$db")"
  per=$(cmp_su_judge_uni "$db")
  log "  [$tag] 起点：seq/unseq 去重=$(printf '%s' "$per") 字节=$(cmp_bytes_sum "$db") TsFile=$(cmp_all_sum "$db") unseq=$(cmp_unseq_sum "$db") mods=$(cmp_mods_sum "$db") 布局=$(cmp_lay "$db")"; }

# ---------------------------------------------------------------- 场景有效性硬闸
# 只要"构造 INSERT 失败 / 关键行数对不上"就判**场景无效**（只留一条 FAIL），随后**跳过后续相位的判据**。
# RC8 教训：`co36_ins` 曾把 INSERT 响应整段丢掉 ⇒ 空隙批 101 点实际 0 行，17 条下游断言全部误判。
C36_ABORT=0
co36_scene_gate(){ local tag=$1 ok=$2 det=$3
  [ "$ok" = 1 ] && return 0
  fail "  场景无效[$tag]：$det（本轮 INSERT 失败计数=${C36_INS_ERR}，原始响应见上方 ins| 行）⇒ 跳过后续相位判据，先修场景"
  C36_ABORT=1; return 1; }
co36_maybe_abort(){ [ "${C36_ABORT:-0}" = 1 ] || return 0
  log "--- 场景无效 ⇒ 不再执行后续相位的判据（避免 17 条下游断言全部误判），直接收尾 ---"
  post_checks "" tree
  cmp_case_finish "" tree ""
  exit 0; }

# ============================================================ 0) 集群准备（写入期三类合并全关）
log "--- 0) 集群准备：三类合并全关（CMP_EXTRA_WRITE）；interval=${CMP_INTERVAL_MS}ms ---"
C36_EXTRA="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${CMP_CANDIDATE_NUM},compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0"
EXTRA_CONF="$C36_EXTRA" cmp_cluster_prepare
for kv in inner_compaction_candidate_file_num max_level_gap_in_inner_compaction min_cross_compaction_unseq_file_level; do
  want=$(printf '%s' "$C36_EXTRA" | tr ',' '\n' | grep -E "^${kv}=" | cut -d= -f2-)
  co36_eff "$kv" "$want"
done
log "  注：min_cross_compaction_unseq_file_level=0 是**必须**的 —— 默认 1 时小 unseq 文件（size < target_compaction_file_size）"
log "      没被内部合并过就不会被 cross 选中（源码 RewriteCrossSpaceCompactionSelector:307）"

# ============================================================ 1) 假 overlap + ALL_DELETED（cross, fast）
log "--- 1) 假 overlap + ALL_DELETED：${DBF}（cross_performer=fast）---"
F_BASE=$(( $(now_ms) - 7200000 ))
H_FROM=100; H_TO=$(( 100 + HOLE_N - 1 ))
D_FROM=300; D_TO=$(( 300 + DEL_N - 1 ))
log "  场景：seq 端点 [0,${SPAN}]；unseq 空隙 [${H_FROM},${H_TO}] ⊂ (0,${SPAN})；ALL_DELETED 段 [${D_FROM},${D_TO}]"
co36_fake_scene "$DBF" "1" "$F_BASE" "$SPAN" "$HOLE_N" with_delete
F_SU_UNI=$(cmp_su_judge_uni "$DBF")
F_ROWS=$(co36_rows "$DBF")
F_ROWS_HOLE=$(co36_rows_range "$DBF" "$(( F_BASE + H_FROM ))" "$(( F_BASE + H_TO ))")
F_ROWS_DEL=$(co36_rows_range "$DBF" "$(( F_BASE + D_FROM ))" "$(( F_BASE + D_TO ))")
F_MODS=$(cmp_mods_sum "$DBF")
log "  场景实测：seq/unseq 去重=$(printf '%s' "$F_SU_UNI") 总行数=${F_ROWS}（期望 $(( 2 + HOLE_N ))）空隙=${F_ROWS_HOLE}（期望 ${HOLE_N}）被删段=${F_ROWS_DEL}（期望 0）mods=${F_MODS}"
if [ "$(printf '%s' "$F_SU_UNI" | tr -d ' ')" = "1/2" ]; then
  pass "  场景有效性①：判据集均为 1 个 seq + 2 个 unseq 文件（去重=$(printf '%s' "$F_SU_UNI")）"
else
  fail "  场景未成立：期望判据集 1/2（V1=全部副本 / V2=leader），实际 $(cmp_su "$DBF")"
fi
if [ "${H_FROM:-0}" -gt 0 ] && [ "${H_TO:-0}" -lt "${SPAN:-0}" ]; then
  pass "  场景有效性②：空隙区间 [${H_FROM},${H_TO}] **严格落在** seq 区间 (0,${SPAN}) 内部（不是普通 overlap）"
else
  fail "  场景未成立：空隙区间 [${H_FROM},${H_TO}] 未严格落在 (0,${SPAN}) 内部（会退化成普通 overlap）"
fi
# 场景有效性③是**硬闸**（空隙批必须真的产出 ${HOLE_N} 个点）：不成立就只留一条"场景无效"并跳过后续判据
F_SCENE_OK=1; F_SCENE_DET=""
[ "${F_ROWS_HOLE:-0}" = "$HOLE_N" ] || { F_SCENE_OK=0; F_SCENE_DET="$F_SCENE_DET 空隙段行数=${F_ROWS_HOLE:-0}(期望 ${HOLE_N})"; }
[ "${F_ROWS:-0}" = "$(( 2 + HOLE_N ))" ] || { F_SCENE_OK=0; F_SCENE_DET="$F_SCENE_DET 总行数=${F_ROWS:-0}(期望 $(( 2 + HOLE_N )))"; }
[ "${F_ROWS_DEL:-0}" = 0 ] || { F_SCENE_OK=0; F_SCENE_DET="$F_SCENE_DET 被删段=${F_ROWS_DEL:-0}(期望 0)"; }
co36_scene_gate "1/假 overlap+ALL_DELETED" "$F_SCENE_OK" "$F_SCENE_DET"
if [ "$F_SCENE_OK" = 1 ]; then
  pass "  场景有效性③：端点行+空隙行可见（${F_ROWS}/${F_ROWS_HOLE}），被删段查询 0 行（DELETE 已生效）"
fi
co36_maybe_abort
F_BYTES0=$(cmp_bytes_sum "$DBF"); F_MAX0=$(cmp_max_tsfile_bytes_sum "$DBF")
F_SUM0=$(cmp_all_sum "$DBF"); F_UNSEQ0=$(cmp_unseq_sum "$DBF")
F_FIN0=$(cmp_cross_finish "$DBF"); F_FP0=$(cmp_fp_tree "$DBF")
log "  基线：字节=${F_BYTES0} 最大文件=${F_MAX0} TsFile=${F_SUM0}(unseq=${F_UNSEQ0}) cross finishes=${F_FIN0} 指纹=[$F_FP0]"
if [ "${F_UNSEQ0:-0}" -ge 1 ] && [ "$(cmp_seq_sum "$DBF")" -ge 1 ]; then
  pass "  场景有效性④：开合并前 seq≥1 且 unseq≥1（seq=$(cmp_seq_sum "$DBF") unseq=${F_UNSEQ0}）"
else
  fail "  场景未成立：开合并前 seq=$(cmp_seq_sum "$DBF") unseq=${F_UNSEQ0}（两者都要 ≥1）"
fi
co36_files "$DBF" | sed 's/^/    src /' >>"$OUT"
log "  SET cross_performer=fast → $(cmp_set_hot cross_performer fast | tr '\n' ' ' | cut -c1-120)"
co36_eff cross_performer fast
cmp_compaction_on false false true
F_RES=$(co36_wait_cross "$DBF" "$F_FIN0" "$WIN_CROSS")
F_FIN1=${F_RES%%|*}; F_UNSEQ1=${F_RES##*|}
cmp_compaction_off
sleep 5
F_BYTES1=$(cmp_bytes_sum "$DBF"); F_SUM1=$(cmp_all_sum "$DBF"); F_FP1=$(cmp_fp_tree "$DBF")
F_ROWS1=$(co36_rows "$DBF")
F_ROWS_HOLE1=$(co36_rows_range "$DBF" "$(( F_BASE + H_FROM ))" "$(( F_BASE + H_TO ))")
F_ROWS_DEL1=$(co36_rows_range "$DBF" "$(( F_BASE + D_FROM ))" "$(( F_BASE + D_TO ))")
F_PFO=$(co36_summary_field "$DBF" PAGE_FAKE_OVERLAP)
log "  终态：cross finishes ${F_FIN0}→${F_FIN1} unseq ${F_UNSEQ0}→${F_UNSEQ1} TsFile ${F_SUM0}→${F_SUM1} 字节 ${F_BYTES0}→${F_BYTES1}"
log "  终态行数：总=${F_ROWS1}（合并前 ${F_ROWS}）空隙=${F_ROWS_HOLE1}（合并前 ${F_ROWS_HOLE}）被删段=${F_ROWS_DEL1}（合并前 ${F_ROWS_DEL}）"
log "  fast 摘要 PAGE_FAKE_OVERLAP 合计=${F_PFO}（含 compaction/all 两个日志 ⇒ 实际按 1/2 记）"
co36_finish_lines "$DBF" | cut -c1-400 | sed 's/^/    fin /' >>"$OUT"
co36_files "$DBF" | sed 's/^/    dst /' >>"$OUT"
if [ "${F_FIN1:-0}" -gt "${F_FIN0:-0}" ] && [ "${F_UNSEQ1:-0}" = 0 ] && [ "${F_SUM1:-0}" -lt "${F_SUM0:-0}" ]; then
  pass "  ① 双信号成立：cross finishes ${F_FIN0}→${F_FIN1}、unseq 归零、TsFile ${F_SUM0}→${F_SUM1}"
else
  fail "  ① 双信号不成立：cross finishes ${F_FIN0}→${F_FIN1}、unseq=${F_UNSEQ1}、TsFile ${F_SUM0}→${F_SUM1}（期望 finishes↑、unseq=0、TsFile↓）"
fi
cmp_assert_same "  ② 合并前后数据指纹（含被删段不得复活）" "$F_FP0" "$F_FP1"
if [ "${F_ROWS1:-0}" = "$F_ROWS" ] && [ "${F_ROWS_HOLE1:-0}" = "$HOLE_N" ] && [ "${F_ROWS_DEL1:-0}" = 0 ]; then
  pass "  ③ 行数核对：总行数不变（${F_ROWS1}）、空隙段数据保留（${F_ROWS_HOLE1} 行）、被删段仍为 0 行（未复活）"
else
  fail "  ③ 行数核对失败：总=${F_ROWS1}（期望 ${F_ROWS}）空隙=${F_ROWS_HOLE1}（期望 ${HOLE_N}）被删段=${F_ROWS_DEL1}（期望 0）"
fi
if [ "${F_BYTES1:-0}" -lt "${F_BYTES0:-0}" ]; then
  pass "  ④ ALL_DELETED 跳过（D5-3）：终态字节 ${F_BYTES1} < 源字节 ${F_BYTES0}（被整段删除的数据没有进产物）"
else
  fail "  ④ 终态字节 ${F_BYTES1} ≥ 源字节 ${F_BYTES0} —— ALL_DELETED 段疑似仍被写进产物"
fi
[ "${F_PFO:-0}" -ge 1 ] && pass "  ⑤ 「假 overlap」page 直刷（D5-2）：fast 摘要 PAGE_FAKE_OVERLAP=${F_PFO} ≥ 1（产品日志自报，见 fin 行）" \
  || fail "  ⑤ 未观测到 page 级直搬：PAGE_FAKE_OVERLAP=${F_PFO}（期望 ≥1）。判缺陷前先看：① fin 行里有没有 fast 摘要（若整行没有 *_OVERLAP 计数器，说明本构建没走 fast 摘要，属**判据不可用**而非缺陷）；② 3) 的负向对照是否 =0、PAGE_OVERLAP_OR_MODIFIED 是否 ≥1（用来确认计数器本身有效）"
warn "CO-36 诚实标注：产物 page 与源 page 的**逐字节**比对仍未做（脚本没有读 TsFile page offset/length 的工具），只做到产品自报的 page 级直搬计数 + 文件级字节/名字记录"

# ============================================================ 2) D5-1 直搬体积（fast vs read_point）
log "--- 2) D5-1 直搬体积：${DBD}(fast) vs ${DBM}(read_point)，同一「假 overlap（无删除）」构造 ---"
D_BASE=$(( $(now_ms) - 7200000 ))
co36_fake_scene "$DBD" "2A-fast" "$D_BASE" "$BIG_SPAN" "$BIG_HOLE_N" no_delete
D_SU_UNI=$(cmp_su_judge_uni "$DBD")
if [ "$(printf '%s' "$D_SU_UNI" | tr -d ' ')" = "1/1" ]; then
  pass "  场景成立：各副本 1 seq + 1 unseq（空隙 [100,$(( 100 + BIG_HOLE_N - 1 ))] ⊂ (0,${BIG_SPAN})）"
else
  co36_scene_gate "2A-fast/假 overlap" 0 "期望判据集 1/1（V1=全部副本 / V2=leader），实际 $(cmp_su "$DBD")"
  co36_maybe_abort
fi
D_BYTES0=$(cmp_bytes_sum "$DBD"); D_SUM0=$(cmp_all_sum "$DBD"); D_UNSEQ0=$(cmp_unseq_sum "$DBD")
D_FIN0=$(cmp_cross_finish "$DBD"); D_FP0=$(cmp_fp_tree "$DBD")
log "  SET cross_performer=fast → $(cmp_set_hot cross_performer fast | tr '\n' ' ' | cut -c1-120)"
co36_eff cross_performer fast
cmp_compaction_on false false true
D_RES=$(co36_wait_cross "$DBD" "$D_FIN0" "$WIN_CROSS")
D_FIN1=${D_RES%%|*}; D_UNSEQ1=${D_RES##*|}
cmp_compaction_off
sleep 5
D_BYTES1=$(cmp_bytes_sum "$DBD"); D_SUM1=$(cmp_all_sum "$DBD"); D_FP1=$(cmp_fp_tree "$DBD")
D_RATIO=$(co36_ratio "$D_BYTES1" "$D_BYTES0"); D_PFO=$(co36_summary_field "$DBD" PAGE_FAKE_OVERLAP)
log "  [fast] 终态：finishes ${D_FIN0}→${D_FIN1} unseq ${D_UNSEQ0}→${D_UNSEQ1} TsFile ${D_SUM0}→${D_SUM1} 字节 ${D_BYTES0}→${D_BYTES1}（=源×${D_RATIO}%）PAGE_FAKE_OVERLAP=${D_PFO}"
if [ "${D_FIN1:-0}" -gt "${D_FIN0:-0}" ] && [ "${D_UNSEQ1:-0}" = 0 ] && [ "${D_SUM1:-0}" -lt "${D_SUM0:-0}" ]; then
  pass "  [fast] 双信号成立：finishes ${D_FIN0}→${D_FIN1}、unseq 归零、TsFile ${D_SUM0}→${D_SUM1}"
else
  fail "  [fast] 双信号不成立：finishes ${D_FIN0}→${D_FIN1}、unseq=${D_UNSEQ1}、TsFile ${D_SUM0}→${D_SUM1}"
fi
cmp_assert_same "  [fast] 合并前后数据指纹" "$D_FP0" "$D_FP1"
[ "${D_PFO:-0}" -ge 1 ] && pass "  [fast] 走 fast 路径且发生 page 级直搬（PAGE_FAKE_OVERLAP=${D_PFO}）" \
  || fail "  [fast] 未观测到 page 级直搬（PAGE_FAKE_OVERLAP=${D_PFO}）；先确认 fin 行里是否有 fast 摘要计数器（没有则是判据不可用，不是缺陷）"
M_BASE=$(( $(now_ms) - 7200000 ))
co36_fake_scene "$DBM" "2B-read_point" "$M_BASE" "$BIG_SPAN" "$BIG_HOLE_N" no_delete
M_BYTES0=$(cmp_bytes_sum "$DBM"); M_SUM0=$(cmp_all_sum "$DBM"); M_UNSEQ0=$(cmp_unseq_sum "$DBM")
M_FIN0=$(cmp_cross_finish "$DBM"); M_FP0=$(cmp_fp_tree "$DBM")
log "  SET cross_performer=read_point → $(cmp_set_hot cross_performer read_point | tr '\n' ' ' | cut -c1-120)"
# `cross_performer` 合法取值只有 {read_point, fast}（CrossCompactionPerformer.java:31-46）⇒ 本相用 read_point。
co36_eff cross_performer read_point
log "  read_point 相不用 fast 专有计数器（本相 PAGE_FAKE_OVERLAP 期望 0，见下面可观测性断言）"
cmp_compaction_on false false true
M_RES=$(co36_wait_cross "$DBM" "$M_FIN0" "$WIN_CROSS")
M_FIN1=${M_RES%%|*}; M_UNSEQ1=${M_RES##*|}
cmp_compaction_off
sleep 5
M_BYTES1=$(cmp_bytes_sum "$DBM"); M_SUM1=$(cmp_all_sum "$DBM"); M_FP1=$(cmp_fp_tree "$DBM")
M_RATIO=$(co36_ratio "$M_BYTES1" "$M_BYTES0"); M_PFO=$(co36_summary_field "$DBM" PAGE_FAKE_OVERLAP)
log "  [read_point] 终态：finishes ${M_FIN0}→${M_FIN1} unseq ${M_UNSEQ0}→${M_UNSEQ1} TsFile ${M_SUM0}→${M_SUM1} 字节 ${M_BYTES0}→${M_BYTES1}（=源×${M_RATIO}%）PAGE_FAKE_OVERLAP=${M_PFO}"
if [ "${M_FIN1:-0}" -gt "${M_FIN0:-0}" ] && [ "${M_UNSEQ1:-0}" = 0 ] && [ "${M_SUM1:-0}" -lt "${M_SUM0:-0}" ]; then
  pass "  [read_point] 双信号成立：finishes ${M_FIN0}→${M_FIN1}、unseq 归零、TsFile ${M_SUM0}→${M_SUM1}"
else
  fail "  [read_point] 双信号不成立：finishes ${M_FIN0}→${M_FIN1}、unseq=${M_UNSEQ1}、TsFile ${M_SUM0}→${M_SUM1}"
fi
cmp_assert_same "  [read_point] 合并前后数据指纹" "$M_FP0" "$M_FP1"
co36_finish_lines "$DBM" | cut -c1-300 | sed 's/^/    fin(rc) /' >>"$OUT"
if [ "${D_RATIO:-0}" -ge "$MOVE_RATIO_MIN" ]; then
  pass "  ⑥ 直搬体积（D5-1）：fast 相终态字节 = 源 × ${D_RATIO}%（≥ ${MOVE_RATIO_MIN}%）⇒ 无重叠 chunk/page 未被清洗重写"
else
  if [ "${D_BYTES1:-0}" = "${M_BYTES1:-0}" ]; then
    warn "  ⑥ 直搬体积判据降级：fast 相终态字节 = 源 × ${D_RATIO}%（< ${MOVE_RATIO_MIN}%），但与 read_point 完全相同（${D_BYTES1}B）⇒ 本版本两种 performer 在**体积**上无可观测差异；page 级直搬仍由 ⑤ 的 PAGE_FAKE_OVERLAP≥1 证明，按 §5 防误判**不判产品缺陷**"
  else
    fail "  ⑥ 直搬体积不成立：fast 相终态字节 = 源 × ${D_RATIO}%（< ${MOVE_RATIO_MIN}%）且 read_point=${M_BYTES1}B 不同（${D_BYTES1}B）⇒ 疑似 fast 路径未走直搬（D5-1）"
  fi
fi
if [ "${M_PFO:-0}" = 0 ] && [ "${D_PFO:-0}" -ge 1 ]; then
  pass "  performer 切换可观测：fast 自报 PAGE_FAKE_OVERLAP=${D_PFO}，read_point 无该计数器（read_point 任务打印普通 CompactionTaskSummary）"
else
  warn "  performer 切换的可观测性异常：fast PAGE_FAKE_OVERLAP=${D_PFO} read_point PAGE_FAKE_OVERLAP=${M_PFO}（如实记录）"
fi
if [ "${D_BYTES1:-0}" != "${M_BYTES1:-0}" ]; then
  log "  fast vs read_point 产物字节：fast=${D_BYTES1}B（源×${D_RATIO}%） vs read_point=${M_BYTES1}B（源×${M_RATIO}%）"
fi

# ============================================================ 3) 真 overlap 负向对照（PAGE_FAKE_OVERLAP 必须为 0）
log "--- 3) 真 overlap 负向对照：${DBT}（seq 端点为 {0,150,${SPAN}} ⇒ 当前点 150 <= 下一页 endTime 200）---"
T_BASE=$(( $(now_ms) - 7200000 ))
cmp_compaction_off
co36_mkdb "$DBT"
co36_endpoints3 "$DBT" "$T_BASE" "$SPAN"
cmp_wait_close "$DBT" 1 120 >/dev/null || warn "  [$DBT] seq 端点批 close 未达 1"
cmp_wait_lay "$DBT" "1/0/0/0" 150 >/dev/null || warn "  [$DBT] 布局=$(cmp_lay "$DBT")"
co36_seg "$DBT" "$T_BASE" 100 "$HOLE_N" 50      # 偏移 50 对应 t0+150（与 seq 端点重合）⇒ 跳过，避免同时间戳去重干扰指纹
cmp_wait_close "$DBT" 2 120 >/dev/null || warn "  [$DBT] 空隙批 close 未达 2"
cmp_wait_su "$DBT" "1/1" 150 >/dev/null || warn "  [$DBT] seq/unseq=$(cmp_su "$DBT")（期望判据集 1/1）"
T_ROWS=$(co36_rows "$DBT")
T_SU_UNI=$(cmp_su_judge_uni "$DBT")
log "  场景：各副本 seq/unseq 去重=$(printf '%s' "$T_SU_UNI") 行数=${T_ROWS}（期望 $(( 3 + HOLE_N - 1 ))）"
if [ "$(printf '%s' "$T_SU_UNI" | tr -d ' ')" = "1/1" ]; then
  pass "  场景成立：seq 文件含中间点 150（真 overlap），unseq 落在 [100,200] 且跳过 150"
else
  co36_scene_gate "3/真 overlap" 0 "期望判据集 1/1（V1=全部副本 / V2=leader），实际 $(cmp_su "$DBT")"
  co36_maybe_abort
fi
T_BYTES0=$(cmp_bytes_sum "$DBT"); T_SUM0=$(cmp_all_sum "$DBT"); T_UNSEQ0=$(cmp_unseq_sum "$DBT")
T_FIN0=$(cmp_cross_finish "$DBT"); T_FP0=$(cmp_fp_tree "$DBT")
log "  SET cross_performer=fast → $(cmp_set_hot cross_performer fast | tr '\n' ' ' | cut -c1-120)"
co36_eff cross_performer fast
cmp_compaction_on false false true
T_RES=$(co36_wait_cross "$DBT" "$T_FIN0" "$WIN_CROSS")
T_FIN1=${T_RES%%|*}; T_UNSEQ1=${T_RES##*|}
cmp_compaction_off
sleep 5
T_SUM1=$(cmp_all_sum "$DBT"); T_FP1=$(cmp_fp_tree "$DBT"); T_ROWS1=$(co36_rows "$DBT")
T_PFO=$(co36_summary_field "$DBT" PAGE_FAKE_OVERLAP)
T_POM=$(co36_summary_field "$DBT" PAGE_OVERLAP_OR_MODIFIED)
log "  [真 overlap] 终态：finishes ${T_FIN0}→${T_FIN1} unseq ${T_UNSEQ0}→${T_UNSEQ1} TsFile ${T_SUM0}→${T_SUM1} 行数 ${T_ROWS}→${T_ROWS1} PAGE_FAKE_OVERLAP=${T_PFO} PAGE_OVERLAP_OR_MODIFIED=${T_POM}"
if [ "${T_FIN1:-0}" -gt "${T_FIN0:-0}" ] && [ "${T_UNSEQ1:-0}" = 0 ] && [ "${T_SUM1:-0}" -lt "${T_SUM0:-0}" ]; then
  pass "  [真 overlap] 双信号成立：finishes ${T_FIN0}→${T_FIN1}、unseq 归零、TsFile ${T_SUM0}→${T_SUM1}"
else
  fail "  [真 overlap] 双信号不成立：finishes ${T_FIN0}→${T_FIN1}、unseq=${T_UNSEQ1}、TsFile ${T_SUM0}→${T_SUM1}"
fi
cmp_assert_same "  [真 overlap] 合并前后数据指纹" "$T_FP0" "$T_FP1"
[ "${T_ROWS1:-0}" = "$T_ROWS" ] && pass "  [真 overlap] 行数不变（${T_ROWS1}）" \
  || fail "  [真 overlap] 行数变化：${T_ROWS} → ${T_ROWS1}"
assert_eq "  [真 overlap] 负向对照：PAGE_FAKE_OVERLAP 应为 0" "${T_PFO:-0}" "0"
[ "${T_POM:-0}" -ge 1 ] && pass "  [真 overlap] 走了『重叠/已修改 page 需解开』分支（PAGE_OVERLAP_OR_MODIFIED=${T_POM}）⇒ 与假 overlap 相形成对照" \
  || fail "  [真 overlap] PAGE_OVERLAP_OR_MODIFIED=${T_POM}（期望 ≥1，否则对照场景无效）"

# ============================================================ 4) inner_unseq_performer=fast（2 个重叠 unseq）
log "--- 4) inner unseq 内部合并：${DBU}（inner_unseq_performer=fast，2 个互相重叠的 unseq 文件）---"
cmp_compaction_off
co36_mkdb "$DBU"
U_BASE=$(( $(now_ms) - 7200000 ))
co36_seg "$DBU" "$U_BASE" 50000 "$UNSEQ_N"
cmp_wait_close "$DBU" 1 120 >/dev/null || warn "  [$DBU] 水位批 close 未达 1"
cmp_wait_lay "$DBU" "1/0/0/0" 150 >/dev/null || warn "  [$DBU] 水位批布局=$(cmp_lay "$DBU")"
co36_seg "$DBU" "$U_BASE" 20000 "$UNSEQ_N"
cmp_wait_close "$DBU" 2 120 >/dev/null || warn "  [$DBU] unseq#1 close 未达 2"
co36_seg "$DBU" "$U_BASE" 20100 "$UNSEQ_N"
cmp_wait_close "$DBU" 3 120 >/dev/null || warn "  [$DBU] unseq#2 close 未达 3"
cmp_wait_su "$DBU" "1/2" 150 >/dev/null || warn "  [$DBU] seq/unseq=$(cmp_su "$DBU")（期望判据集 1/2）"
U_SU=$(cmp_su_judge_uni "$DBU")
U_SUM0=$(cmp_all_sum "$DBU"); U_UNSEQ0=$(cmp_unseq_sum "$DBU")
U_FIN0=$(cmp_unseq_inner_finish "$DBU"); U_FP0=$(cmp_fp_tree "$DBU")
log "  起点：seq/unseq 去重=$(printf '%s' "$U_SU") TsFile=${U_SUM0}(unseq=${U_UNSEQ0}) unseq-inner finishes=${U_FIN0} 布局=$(cmp_lay "$DBU") 指纹=[$U_FP0]"
if [ "$(printf '%s' "$U_SU" | tr -d ' ')" = "1/2" ]; then
  pass "  场景成立：各副本 1 seq + 2 unseq（两批时间区间互相重叠：[20000,$(( 20000 + UNSEQ_N - 1 ))] ∩ [20100,$(( 20100 + UNSEQ_N - 1 ))]）"
else
  co36_scene_gate "4/inner unseq fast" 0 "期望判据集 1/2（V1=全部副本 / V2=leader），实际 $(cmp_su "$DBU")"
  co36_maybe_abort
fi
log "  SET inner_unseq_performer=fast → $(cmp_set_hot inner_unseq_performer fast | tr '\n' ' ' | cut -c1-120)"
co36_eff inner_unseq_performer fast
cmp_compaction_on false true false
U_FIN1=$(co36_wait_inner "$DBU" "$U_FIN0" "$U_SUM0" unseq "$WIN_INNER")
cmp_compaction_off
sleep 5
U_SUM1=$(cmp_all_sum "$DBU"); U_FP1=$(cmp_fp_tree "$DBU"); U_UNSEQ1=$(cmp_unseq_sum "$DBU")
U_CNO=$(co36_summary_field "$DBU" CHUNK_NONE_OVERLAP); U_PFO=$(co36_summary_field "$DBU" PAGE_FAKE_OVERLAP)
log "  终态：unseq-inner finishes ${U_FIN0}→${U_FIN1} unseq ${U_UNSEQ0}→${U_UNSEQ1} TsFile ${U_SUM0}→${U_SUM1} 布局=$(cmp_lay "$DBU")"
log "  fast 摘要：CHUNK_NONE_OVERLAP=${U_CNO} PAGE_FAKE_OVERLAP=${U_PFO}"
co36_finish_lines "$DBU" | cut -c1-400 | sed 's/^/    fin /' >>"$OUT"
if [ "${U_FIN1:-0}" -gt "${U_FIN0:-0}" ] && [ "${U_SUM1:-0}" -lt "${U_SUM0:-0}" ] && [ "${U_UNSEQ1:-0}" -lt "${U_UNSEQ0:-0}" ]; then
  pass "  ⑦ inner unseq 双信号成立：finishes ${U_FIN0}→${U_FIN1}、unseq ${U_UNSEQ0}→${U_UNSEQ1}、TsFile ${U_SUM0}→${U_SUM1}"
else
  fail "  ⑦ inner unseq 双信号不成立：finishes ${U_FIN0}→${U_FIN1}、unseq ${U_UNSEQ0}→${U_UNSEQ1}、TsFile ${U_SUM0}→${U_SUM1}"
fi
cmp_assert_same "  ⑦ inner unseq 合并前后数据指纹" "$U_FP0" "$U_FP1"
if [ $(( U_CNO + U_PFO )) -ge 1 ]; then
  pass "  ⑦ fast 路径有可观测计数（CHUNK_NONE_OVERLAP=${U_CNO} PAGE_FAKE_OVERLAP=${U_PFO}）⇒ inner_unseq_performer=fast 确实生效"
else
  warn "  ⑦ fast 摘要里 CHUNK_NONE_OVERLAP/PAGE_FAKE_OVERLAP 都是 0（本场景两个 unseq 文件互相重叠 ⇒ 全部走解开路径）——按 §5 记录，不判缺陷"
fi

# ============================================================ 5) inner_seq_performer=fast（2 个不重叠 seq）
log "--- 5) inner seq 内部合并：${DBI}（inner_seq_performer=fast，2 个**不重叠** seq 文件）---"
cmp_compaction_off
co36_mkdb "$DBI"
I_BASE=$(( $(now_ms) - 7200000 ))
co36_seg "$DBI" "$I_BASE" 0 "$INNER_N"
cmp_wait_close "$DBI" 1 120 >/dev/null || warn "  [$DBI] 批1 close 未达 1"
cmp_wait_lay "$DBI" "1/0/0/0" 150 >/dev/null || warn "  [$DBI] 批1 布局=$(cmp_lay "$DBI")"
co36_seg "$DBI" "$I_BASE" 100000 "$INNER_N"
cmp_wait_close "$DBI" 2 120 >/dev/null || warn "  [$DBI] 批2 close 未达 2"
cmp_wait_lay "$DBI" "2/0/0/0" 150 >/dev/null || warn "  [$DBI] 批2 布局=$(cmp_lay "$DBI")（期望 2/0/0/0）"
I_LAY0=$(cmp_lay "$DBI"); I_UNI=$(printf '%s' "$(cmp_lay_uni "$I_LAY0")" | tr -d ' ')
I_SUM0=$(cmp_all_sum "$DBI"); I_BYTES0=$(cmp_bytes_sum "$DBI")
I_FIN0=$(cmp_seq_inner_finish "$DBI"); I_FP0=$(cmp_fp_tree "$DBI")
log "  起点：布局=$(cmp_lay "$I_LAY0")（去重=${I_UNI}）字节=${I_BYTES0} TsFile=${I_SUM0} seq-inner finishes=${I_FIN0} 指纹=[$I_FP0]"
if [ "$I_UNI" = "2/0/0/0" ]; then
  pass "  场景成立：各副本恰有 2 个不重叠的 level-0 seq 文件（$(cmp_lay "$I_LAY0")）"
else
  co36_scene_gate "5/inner seq fast" 0 "期望各副本 2/0/0/0，实际 $(cmp_lay "$I_LAY0")"
  co36_maybe_abort
fi
log "  SET inner_seq_performer=fast → $(cmp_set_hot inner_seq_performer fast | tr '\n' ' ' | cut -c1-120)"
co36_eff inner_seq_performer fast
cmp_compaction_on true false false
I_FIN1=$(co36_wait_inner "$DBI" "$I_FIN0" "$I_SUM0" seq "$WIN_INNER")
cmp_compaction_off
sleep 5
I_SUM1=$(cmp_all_sum "$DBI"); I_FP1=$(cmp_fp_tree "$DBI"); I_BYTES1=$(cmp_bytes_sum "$DBI")
I_RATIO=$(co36_ratio "$I_BYTES1" "$I_BYTES0")
I_CNO=$(co36_summary_field "$DBI" CHUNK_NONE_OVERLAP)
I_CBD=$(co36_summary_field "$DBI" CHUNK_NONE_OVERLAP_BUT_DESERIALIZE)
I_COMP=$(co36_summary_field "$DBI" CHUNK_OVERLAP_OR_MODIFIED)
log "  终态：seq-inner finishes ${I_FIN0}→${I_FIN1} TsFile ${I_SUM0}→${I_SUM1} 字节 ${I_BYTES0}→${I_BYTES1}（=源×${I_RATIO}%）布局=$(cmp_lay "$DBI")"
log "  fast 摘要：CHUNK_NONE_OVERLAP=${I_CNO} CHUNK_NONE_OVERLAP_BUT_DESERIALIZE=${I_CBD} CHUNK_OVERLAP_OR_MODIFIED=${I_COMP}"
co36_finish_lines "$DBI" | cut -c1-400 | sed 's/^/    fin /' >>"$OUT"
if [ "${I_FIN1:-0}" -gt "${I_FIN0:-0}" ] && [ "${I_SUM1:-0}" -lt "${I_SUM0:-0}" ]; then
  pass "  ⑧ inner seq 双信号成立：finishes ${I_FIN0}→${I_FIN1} 且 TsFile ${I_SUM0}→${I_SUM1}"
else
  fail "  ⑧ inner seq 双信号不成立：finishes ${I_FIN0}→${I_FIN1}、TsFile ${I_SUM0}→${I_SUM1}"
fi
cmp_assert_same "  ⑧ inner seq 合并前后数据指纹" "$I_FP0" "$I_FP1"
if [ "${I_CNO:-0}" -ge 1 ]; then
  pass "  ⑧ 无重叠 chunk 直接搬（D5-1）：CHUNK_NONE_OVERLAP=${I_CNO} ≥ 1（fast ⇒ 未清洗重写）"
elif [ "${I_CBD:-0}" -ge 1 ]; then
  warn "  ⑧ 非重叠 chunk 走了『解序列化』分支（CHUNK_NONE_OVERLAP_BUT_DESERIALIZE=${I_CBD}，源码 L178-181：未封口 chunk 太小 / chunk.endTime > file.endTime 时会这样）⇒ 本场景无直搬证据，按 §5 记录，不判缺陷"
else
  fail "  ⑧ fast 摘要里 CHUNK_NONE_OVERLAP 与 CHUNK_NONE_OVERLAP_BUT_DESERIALIZE 都是 0 ⇒ 两个不重叠的 seq 文件没有走非重叠分支（CHUNK_OVERLAP_OR_MODIFIED=${I_COMP}）"
fi

# ============================================================ 收尾
cmp_assert_no_stuck "无卡死合并线程（TsFileResource.writeLock）"
log "--- 收尾三件套（基准库 root.cofkd：假 overlap 相、数据量最大） ---"
post_checks "select count(s1) from ${DBD}.**;" tree
cmp_case_finish "" tree ""
