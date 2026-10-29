#!/bin/bash
# ============================================================================
# CR-05 Mod 文件的"分配分界"（阈值 n_threshold / size_threshold / should_allocate）
#       —— 存储模块 CRUD 专项 skill
#
# 覆盖需求点（逐字原文见 docs/REQ_MATRIX.md §1）：
#   R-21 "如果 n_modf >= 一个层级 Mod 文件数阈值 n_threshold， 则返回 false，否则返回
#         size(mod_last) >= Mod 大小阈值 size_threshold；n_threshold 和 size_threshold
#         均为可配置参数。"（出处：数据删除功能V2 设计文档·should_allocate 的基本实现）
#
# ★★ 本构建（RC7 `7c61428`）的关键事实（矩阵 §4-B1/B2/B6 已核实，务必按它写）：
#   · 两个阈值在源码里是**硬编码私有常量**：`PartitionLevelModFileManager.java:36-37`
#       `private final int levelModFileNumThreshold = 30;`
#       `private final long singleModFileSizeThresholdByte = 16 * 1024L;`
#     配置模板中**查不到**任何对应键 ⇒ **不能热改参数**，本用例不引用、不热改它们，
#     只用 `cmp_tpl_has` 做"模板里有没有这个键"的**静态核验**，并把
#     "文档说可配置 / 实现是 private final 硬编码" 作为 **WARN 记录**（矩阵 §4-B2）。
#   · `tryShare/allocateNew`（阈值真正生效的地方）只在共享分支被调用：
#     `TsFileResource.prepareModFileForWrite()` 里 `if (useSharedModFile) modFileManagement.allocateFor(this)`；
#     而 `useSharedModFile = false` 是**编译期常量** ⇒ 本构建**每个 TsFile 一个独占
#     `<tsfile>.mods2`**，阈值分支**根本走不到** ⇒ "多个 TsFile 共享同一个 .mods2"
#     **不可观测**（矩阵 §4-B1；draft §3 CR-05 步骤 3 的"期望共享"在本构建必然不成立，
#     本用例按构建事实断言 **1:1 独占**，并把差异 WARN 记录）。
#   · R-37（should_allocate 进阶实现：自动算出 n_IO_sum 最小的阈值）在源码中不存在
#     ⇒ 不可构造，只记录。
#
# 因此本用例验证的是**可观测的"分配分界"**（全部为硬判据）：
#   ① 场景有效性：3 个 seq TsFile、删除前无任何 `.mods2`；
#   ② 时间范围不重叠的 TsFile **不分配** Mod 文件（`canSkipDelete` 边界）；
#   ③ 被删除覆盖的 TsFile **恰好 1 个独占 `.mods2`**（1:1，不共享、不跨文件）；
#   ④ 同一文件重复删除 = **只追加**（文件数不变 + 字节数单调增加），并实测 entry 平均字节；
#   ⑤ 把该 `.mods2` 顶到 **16KB 以上**（硬编码 size_threshold）后行为**不变**：
#      不新分配、不共享、其它 TsFile 仍无 Mod 文件 ⇒ 证明"阈值分界在非共享构建下不可观测"；
#   ⑥ 表模型同一组分界 + "整文件覆盖 ⇒ 走文件级删除（不新增 Mod 文件）"的证据（后者只记录/WARN）。
#   ⑦ 数据面：行数/指纹不变、三副本一致；双信号：`[Deletion] … is written into … mod files`
#      行数增加 **且** 文件面变化。
#
# 用法： bash cases/common/cr_mod_alloc_threshold.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：15~25 min（无重启；⑤ 段要批量下发数百条 DELETE）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_mod_alloc_threshold_${DATA_CONSENSUS}"

DB=root.cralloc         # 树模型库
TDB=crallocb            # 表模型库（表模型库名不带 root. 前缀）
TB=t1
ROWS=${CR_MOD_ROWS:-100}
DUP=${CR_ALLOC_DUP:-10}                 # ④ 段重复删除次数
TARGET_B=${CR_ALLOC_TARGET_B:-16384}    # 硬编码 size_threshold = 16 * 1024
APPEND_ROUNDS=${CR_ALLOC_ROUNDS:-16}    # ⑤ 段批量追加轮数上限（每轮 PER_ROUND 条，达到 16KB 即提前退出）
PER_ROUND=${CR_ALLOC_PER_ROUND:-40}     # 每轮 40 条 DELETE（同一个 CLI 会话）

# ===========================================================================
# Mod 文件观测 helper（与 CR-04 同一套；只用 lib 已有能力）
# ===========================================================================
crm_find(){ local h=$1 db=$2 suf=$3
  sshx "$h" "find $DB_DIR/data/datanode/data -name '*$suf' -printf '%p|%s\n' 2>/dev/null" 2>/dev/null \
  | awk -F'|' -v db="$db" '{n=split($1,a,"/"); for(i=1;i<=n;i++){c=a[i]; if(c==db||c=="root."db||index(c,db"-")==1||index(c,"root."db"-")==1){print a[n]"|"$2; next}}}'; }
crm_mods(){  crm_find "$1" "$2" '.mods2' | sort; }
crm_excl(){  crm_find "$1" "$2" '.tsfile.mods2' | sort; }
crm_tslist(){ crm_find "$1" "$2" '.tsfile' | sort; }
crm_cnt(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | wc -l | tr -dc '0-9'; }
crm_cnt_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_cnt "$h" "$db") )); done; echo "$s"; }
crm_cnts(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(crm_cnt "$h" "$db") "; done; echo "$out"; }
crm_ts_cnt(){ printf '%s\n' "$(crm_tslist "$1" "$2")" | sed '/^$/d' | wc -l | tr -dc '0-9'; }
crm_ts_cnts(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(crm_ts_cnt "$h" "$db") "; done; echo "$out"; }
crm_bytes(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | awk -F'|' '{s+=$2} END{print s+0}'; }
crm_bytes_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_bytes "$h" "$db") )); done; echo "$s"; }
crm_owners(){ crm_excl "$1" "$2" | sed 's/\.mods2|.*$//' | tr '\n' ' ' | sed 's/ *$//'; }
crm_tsnames(){ crm_tslist "$1" "$2" | sed 's/|[0-9]*$//' | tr '\n' ' ' | sed 's/ *$//'; }   # 保留 .tsfile 后缀
crm_kinds(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | awk -F'|' '{n=$1}
    n ~ /\.compaction\.mods2$/   {c++; next}
    n ~ /\.tsfile\.mods2$/       {e++; next}
    n ~ /^[0-9]+-[0-9]+\.mods2$/ {s++; next}
    {o++}
    END{printf "exclusive=%d shared=%d cmod=%d other=%d", e+0, s+0, c+0, o+0}'; }
crm_kind_of(){ printf '%s' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }
# 共享命名 / C_Mod / 新分配一旦出现：与本构建的独占事实冲突 ⇒ 只 WARN（构建变更探测）
crm_shape_note(){ local db=$1 k s c
  k=$(crm_kinds "${DN[0]}" "$db")
  s=$(crm_kind_of "$k" shared); c=$(crm_kind_of "$k" cmod)
  log "  [$db] Mod 文件命名形态：$k"
  if [ "${s:-0}" -eq 0 ] && [ "${c:-0}" -eq 0 ]; then
    pass "[$db] 形态符合本构建（全部独占 <tsfile>.mods2；无共享命名、无 .compaction.mods2）"
  else
    warn "[$db] 出现共享命名/.compaction.mods2（$k）⇒ 构建可能已打开共享 Mod 文件方案；本用例的'阈值不可观测'结论需人工复核"
  fi; }
crm_byte(){ local h=$1 owner=$2 v
  v=$(sshx "$h" "f=\$(find $DB_DIR/data/datanode/data -name '$owner.mods2' 2>/dev/null | head -1); if [ -n \"\$f\" ]; then od -An -tx1 -N1 \"\$f\" | tr -d ' \n'; else echo NA; fi" 2>/dev/null | tr -dc '0-9a-f')
  echo "${v:-NA}"; }
crm_logcnt(){ local h=$1 pat=$2 n
  n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -F '$pat' | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${n:-0}"; }
crm_logsum(){ local pat=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_logcnt "$h" "$pat") )); done; echo "$s"; }
crm_rows_t(){ sq "select $2 from $1 order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9'; }
crm_wait_rows_t(){ local dev=$1 meas=$2 want=$3 t=${4:-90} got deadline
  deadline=$(( $(date +%s) + t ))
  while (( $(date +%s) < deadline )); do
    got=$(crm_rows_t "$dev" "$meas"); got=${got:-0}
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 3
  done; echo "${got:-0}"; return 1; }
crm_wait_rows_b(){ local sql=$1 want=$2 t=${3:-90} got deadline
  deadline=$(( $(date +%s) + t ))
  while (( $(date +%s) < deadline )); do
    got=$(cmp_tbl_rows "$sql"); got=${got:-0}
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 3
  done; echo "${got:-0}"; return 1; }
crm_wait_ts(){ local db=$1 want=$2 t=${3:-150} h n ok deadline i=0
  deadline=$(( $(date +%s) + t ))
  while (( $(date +%s) < deadline )); do
    i=$(( i + 1 )); ok=1
    for h in "${DN[@]}"; do n=$(crm_ts_cnt "$h" "$db"); [ "${n:-0}" = "$want" ] || ok=0; done
    [ "$ok" = 1 ] && { echo "$i"; return 0; }
    sq "flush;" >/dev/null 2>&1
    for h in "${DN[@]}"; do sq_node "$h" "flush;" >/dev/null 2>&1; done
    sleep 6
  done; echo "$i"; return 1; }
# 等各副本 .mods2 数都 == want（DELETE 走共识，副本可能滞后 ⇒ 先等再判）
crm_wait_cnt(){ local db=$1 want=$2 t=${3:-90} h n ok deadline
  deadline=$(( $(date +%s) + t ))
  while (( $(date +%s) < deadline )); do
    ok=1
    for h in "${DN[@]}"; do n=$(crm_cnt "$h" "$db"); [ "${n:-0}" = "$want" ] || ok=0; done
    [ "$ok" = 1 ] && return 0
    sleep 3
  done
  return 1; }
crm_write_dev(){ local db=$1 dev=$2 rows=$3 base=$4 b=${5:-1} k vals=""
  for ((k=0;k<rows;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.$dev(time,s1) values ${vals%,};" >/dev/null || return 1
  sq "flush;" >/dev/null; }
crm_sql(){ local out; out=$(sq "$1" 2>&1)
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException|Exception'; then
    echo "ERR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  return 0; }
crm_sqlt(){ local out; out=$(sqt "$1" 2>&1)
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException|Exception'; then
    echo "ERR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  return 0; }

# ===========================================================================
log "--- 集群准备（三类合并全关；$CMP_EXTRA_WRITE）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"
cmp_compaction_off

# ---------------------------------------------------------------------------
log "--- ① 硬编码阈值核验（静态）：文档称可配置，源码是 private final 30 / 16KB ---"
TPL_HIT=0
for k in level_mod_file_num_threshold single_mod_file_size_threshold_byte mod_file_size_threshold n_threshold size_threshold should_allocate; do
  n=$(cmp_tpl_has "${DN[0]}" "$k")
  log "  配置模板键 $k 出现次数=${n:-0}"
  [ "${n:-0}" -eq 0 ] || { warn "配置模板里存在键 $k（${n} 处）—— 文档的'可配置'可能已落地，请人工复核本用例假设"; TPL_HIT=$(( TPL_HIT + 1 )); }
done
[ "$TPL_HIT" -eq 0 ] && pass "配置模板中无任何 Mod 文件阈值键 ⇒ 阈值确为硬编码（与源码 PartitionLevelModFileManager:36-37 一致）" \
  || true
warn "【实现偏差·记录】R-21 原文称 n_threshold / size_threshold『均为可配置参数』，RC7 实现是 PartitionLevelModFileManager:36-37 的 private final levelModFileNumThreshold=30 / singleModFileSizeThresholdByte=16*1024；本用例**不依赖**配置项，只观测硬编码阈值下的分配行为（矩阵 §4-B2）"
warn "【不可构造·记录】R-37 的 should_allocate 进阶实现（自动算 n_IO_sum 最小阈值并应用到下一个时间分区）在 RC7 源码中不存在 ⇒ 不可构造"

# ---------------------------------------------------------------------------
log "--- ② 树模型：3 个设备各一批（每批 $ROWS 行）⇒ 3 个 seq TsFile ---"
cmp_make_tree_db "$DB" 3
BASE=$(( ($(date +%s) - 600) * 1000 ))
for i in 1 2 3; do
  crm_write_dev "$DB" "d$i" "$ROWS" "$(( BASE + i * 10000 ))" "$i" || fail "写入 $DB.d$i 失败"
  cmp_wait_close "$DB" "$i" 90 >/dev/null || warn "  d$i 批 close 事件未达 $i"
  crm_wait_ts "$DB" "$i" 150 >/dev/null || warn "  d$i 批后 TsFile=$(crm_ts_cnts "$DB")（期望各副本 $i）"
done
TS0=$(crm_ts_cnt "${DN[0]}" "$DB")
log "  起点：TsFile=$(crm_ts_cnts "$DB") mods2=$(crm_cnts "$DB") 行数 d1=$(crm_rows_t "$DB.d1" s1) d2=$(crm_rows_t "$DB.d2" s1)"
[ "${TS0:-0}" -ge 3 ] && pass "场景有效：起点 TsFile=$TS0（≥3）" || fail "场景无效：起点 TsFile=$TS0（<3）"
[ "$(crm_cnt_sum "$DB")" -eq 0 ] && pass "删除前该库无任何 .mods2（R-19 基线成立）" \
  || fail "场景无效：删除前已存在 .mods2（$(crm_mods "${DN[0]}" "$DB" | tr '\n' ' ')）"
mapfile -t TL < <(crm_tsnames "${DN[0]}" "$DB" | tr ' ' '\n' | sed '/^$/d' | sort)
F1=${TL[0]:-}; F2=${TL[1]:-}; F3=${TL[2]:-}
log "  F1=$F1 F2=$F2 F3=$F3（按名排序=按 flush 时间排序）"
[ -n "$F1" ] && [ -n "$F2" ] && [ -n "$F3" ] && pass "已取到 3 个 TsFile 名（供分配分界判据定位）" \
  || fail "场景无效：未取到 3 个 TsFile 名（$(crm_tsnames "${DN[0]}" "$DB")）"
D2FP0=$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")
T1=$(( BASE + 10000 + (ROWS - 1) * 10 ))

# ---------------------------------------------------------------------------
log "--- ③ 分配分界①：删除只覆盖 d1 ⇒ 只有该 TsFile 分配 .mods2（时间不重叠的文件不分配）---"
L0=$(crm_logsum 'is written into')
crm_sql "delete from $DB.d1.** where time <= $T1;" >/dev/null || fail "DELETE d1 报错"
assert_eq "删除后 d1 行数" "$(crm_wait_rows_t "$DB.d1" s1 0 90)" "0"
L1=$(crm_logsum 'is written into')
[ "${L1:-0}" -gt "${L0:-0}" ] && pass "双信号(日志面)：'is written into … mod files' $L0 → $L1" \
  || fail "删除后无 'is written into … mod files' 日志行（双信号缺失）"
crm_wait_cnt "$DB" 1 90 >/dev/null || warn "  .mods2 数未在 90s 内三副本统一为 1（$(crm_cnts "$DB")）——删除可能仍在同步"
OWN=$(crm_owners "${DN[0]}" "$DB")
log "  .mods2 数=$(crm_cnts "$DB") 宿主TsFile=[$OWN]"
for h in "${DN[@]}"; do
  n=$(crm_cnt "$h" "$DB")
  [ "${n:-0}" -eq 1 ] && pass "$h 恰好 1 个独占 .mods2（被删除覆盖的 TsFile）" \
    || fail "$h .mods2 数=$n（期望 1）"
done
printf '%s' "$OWN" | grep -qF "$F1" && pass "分配分界：$F1 被覆盖 ⇒ 分配 $F1.mods2" || fail "分配分界异常：$F1 无 .mods2（宿主=[$OWN]）"
for f in "$F2" "$F3"; do
  printf '%s' "$OWN" | grep -qF "$f" && fail "分配分界异常：时间范围不重叠的 TsFile $f 也被分配了 Mod 文件" \
    || pass "分配分界：时间范围不重叠的 TsFile $f 未分配 Mod 文件"
done
crm_shape_note "$DB"

# ---------------------------------------------------------------------------
log "--- ④ 分配分界②：同一文件重复删除 $DUP 次 ⇒ 只追加（文件数不变 + 字节单调增加）---"
C0=$(crm_cnt_sum "$DB"); P0=$(crm_bytes_sum "$DB"); PREV=$P0
for ((k=1;k<=DUP;k++)); do
  crm_sql "delete from $DB.d1.** where time <= $T1;" >/dev/null || fail "第 $k 次重放 DELETE d1 报错"
  sleep 1
  CUR=$(crm_bytes_sum "$DB")
  log "    第 $k 次重放：字节 $PREV → $CUR（+$(( CUR - PREV ))）"
  [ "${CUR:-0}" -gt "${PREV:-0}" ] || fail "第 $k 次重放未追加删除记录（字节 $PREV → $CUR）"
  PREV=$CUR
done
C1=$(crm_cnt_sum "$DB")
assert_eq "重复删除后 Mod 文件数（必须不变）" "$C1" "$C0"
[ "${PREV:-0}" -gt "${P0:-0}" ] && pass "重复删除只追加：字节 $P0 → $PREV（+$(( PREV - P0 ))，$DUP 次）" \
  || fail "重复删除后字节未增加（$P0 → $PREV）"
ENTRY=$(awk -v a="$P0" -v b="$PREV" -v n="$DUP" 'BEGIN{printf "%.1f", (b-a)/n}')
log "  实测单条删除记录 ≈ ${ENTRY}B（供 ⑤ 段估算『跨 16KB 需要多少条』）"

# ---------------------------------------------------------------------------
log "--- ⑤ 分配分界③：把 .mods2 顶到 ${TARGET_B}B（= 硬编码 size_threshold）以上，看行为是否变化 ---"
SZ=$(crm_bytes "${DN[0]}" "$DB")
round=0
while [ "${SZ:-0}" -lt "$TARGET_B" ] && [ "$round" -lt "$APPEND_ROUNDS" ]; do
  round=$(( round + 1 ))
  before=$SZ
  stmts=()
  for ((k=0;k<PER_ROUND;k++)); do stmts+=("delete from $DB.d1.** where time <= $T1;"); done
  sql_lines_tree "${stmts[@]}" >/dev/null 2>&1
  sleep 2
  SZ=$(crm_bytes "${DN[0]}" "$DB")
  log "    追加轮 $round：$before → ${SZ}B（每轮 $PER_ROUND 条）"
done
log "  ⑤ 段结束：.mods2 字节=${SZ}B（目标 ${TARGET_B}B）、文件数=$(crm_cnts "$DB")、形态=$(crm_kinds "${DN[0]}" "$DB")"
C2=$(crm_cnt_sum "$DB")
assert_eq "跨阈值尝试后 .mods2 文件数（必须仍不变）" "$C2" "$C0"
OWN2=$(crm_owners "${DN[0]}" "$DB")
printf '%s' "$OWN2" | grep -qF "$F1" && pass "宿主 TsFile 仍是 $F1（没有因为文件变大而改分配/新建）" || fail "宿主 TsFile 变化：[$OWN2]"
for f in "$F2" "$F3"; do
  printf '%s' "$OWN2" | grep -qF "$f" && fail "阈值相关异常：$f 在邻居 .mods2 变大后也被分配了 Mod 文件" \
    || pass "$f 仍未分配 Mod 文件（阈值未触发任何新分配）"
done
KS=$(crm_kind_of "$(crm_kinds "${DN[0]}" "$DB")" shared)
[ "${KS:-0}" -eq 0 ] && pass "无任何共享命名 .mods2（<level>-<n>.mods2）：阈值分支在非共享构建下不可达" \
  || warn "出现共享命名 .mods2（shared=$KS）⇒ 阈值分支可能已可达，请人工复核（矩阵 §4-B1）"
if [ "${SZ:-0}" -ge "$TARGET_B" ]; then
  pass "已实测越过 16KB（${SZ}B）：行为**不变**（不新分配、不共享、其它 TsFile 无 Mod 文件）"
else
  warn "⑤ 段在 $APPEND_ROUNDS 轮内未把 .mods2 顶到 ${TARGET_B}B（当前 ${SZ}B，单条≈${ENTRY}B）—— 记录：需要更多追加才能覆盖 size_threshold 分界；本轮已达成的结论是'追加期间始终不新分配'"
fi
warn "⑤ 段结论（记录）：size_threshold（16KB）/ n_threshold（30）只在共享分支 tryShare/allocateNew 里生效，本构建 useSharedModFile=false ⇒ 『多 TsFile 共享同一 .mods2』与『跨阈值新分配』都不可观测；draft §3 CR-05 步骤 3 的『期望共享』判据在本构建不成立（已按构建事实改为 1:1 独占 + 追加语义）"

# ---------------------------------------------------------------------------
log "--- ⑥ 表模型：部分覆盖 ⇒ 分配 .mods2；整文件覆盖 ⇒ 文件级删除（证据）---"
cmp_make_table_db "$TDB" "$TB"
for i in 1 2; do
  cmp_write_table_batch "$TDB" "$TB" 1 "$ROWS" "$i" "$(( BASE + i * 10000 ))"
  cmp_wait_close "$TDB" "$i" 90 >/dev/null || warn "  [$TDB] 批$i close 事件未达 $i"
  crm_wait_ts "$TDB" "$i" 150 >/dev/null || warn "  [$TDB] 批$i 后 TsFile=$(crm_ts_cnts "$TDB")"
done
assert_eq "表模型起点行数" "$(cmp_tbl_rows "select v from $TDB.$TB order by time;")" "$(( ROWS * 2 ))"
mapfile -t TL2 < <(crm_tsnames "${DN[0]}" "$TDB" | tr ' ' '\n' | sed '/^$/d' | sort)
TF1=${TL2[0]:-}; TF2=${TL2[1]:-}
MID=$(( BASE + 10000 + 49 * 10 ))
LT0=$(crm_logsum 'is written into')
crm_sqlt "delete from $TDB.$TB where time <= $MID;" >/dev/null || fail "表模型部分删除报错"
assert_eq "表模型部分删除后行数" "$(crm_wait_rows_b "select v from $TDB.$TB order by time;" "$(( ROWS + 50 ))" 90)" "$(( ROWS + 50 ))"
LT1=$(crm_logsum 'is written into')
[ "${LT1:-0}" -gt "${LT0:-0}" ] && pass "表模型删除写 Mod 文件的日志信号 $LT0 → $LT1" || fail "表模型删除后无 Mod 写入日志（双信号缺失）"
crm_wait_cnt "$TDB" 1 90 >/dev/null || warn "  [$TDB] .mods2 数未在 90s 内三副本统一为 1（$(crm_cnts "$TDB")）"
assert_eq "表模型被部分覆盖的 TsFile 独占 .mods2 数" "$(crm_cnt "${DN[0]}" "$TDB")" "1"
printf '%s' "$(crm_owners "${DN[0]}" "$TDB")" | grep -qF "$TF1" && pass "表模型 $TF1 部分覆盖 ⇒ 分配 Mod 文件" \
  || fail "表模型 $TF1 无 .mods2（宿主=[$(crm_owners "${DN[0]}" "$TDB")]）"
assert_eq "R-22：表模型 Entry 首字节" "$(crm_byte "${DN[0]}" "$TF1")" "00"
T2MAX=$(( BASE + 20000 + (ROWS - 1) * 10 ))
DF0=$(crm_logsum 'directly when delete data')
TC0=$(crm_ts_cnt "${DN[0]}" "$TDB")
crm_sqlt "delete from $TDB.$TB where time <= $T2MAX;" >/dev/null || fail "表模型整文件覆盖删除报错"
assert_eq "表模型整文件覆盖后行数（不得复活）" "$(crm_wait_rows_b "select v from $TDB.$TB order by time;" 0 90)" "0"
DF1=$(crm_logsum 'directly when delete data'); TC1=$(crm_ts_cnt "${DN[0]}" "$TDB")
log "  整文件覆盖：TsFile $TC0 → $TC1；'directly when delete data' $DF0 → $DF1；.mods2=$(crm_cnts "$TDB")"
if [ "${DF1:-0}" -gt "${DF0:-0}" ] || [ "${TC1:-1}" -lt "${TC0:-0}" ]; then
  pass "表模型'整文件覆盖 ⇒ 文件级删除'路径生效（TsFile 数下降、无新 Mod 文件）"
else
  warn "表模型整文件覆盖**未**走文件级删除（TsFile $TC0 → $TC1，.mods2=$(crm_cnts "$TDB")）：依赖 time index 类型/谓词，记录不判 FAIL（R-21 的分配分界以 ③/④/⑤ 的硬判据为准）"
fi

# ---------------------------------------------------------------------------
log "--- ⑦ 数据面：未删除的 d2/d3 行数与指纹不变；三副本一致 ---"
assert_eq "d2 行数" "$(crm_wait_rows_t "$DB.d2" s1 "$ROWS" 60)" "$ROWS"
assert_eq "d1 行数（已被删除）" "$(crm_rows_t "$DB.d1" s1)" "0"
cmp_assert_same "多次追加删除后 d2 全序列指纹" "$D2FP0" "$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")"
for h in "${DN[@]}"; do
  r=$(sq_node "$h" "select s1 from $DB.d2 order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9')
  [ "${r:-0}" = "$ROWS" ] && pass "$h 上 d2 行数=$r（三副本一致）" || fail "$h 上 d2 行数=$r（期望 $ROWS）"
done

log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.d2 order by time;" tree
cmp_case_finish "" tree ""
