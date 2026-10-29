#!/bin/bash
# ============================================================================
# CR-04 `.mods2` 基础形态与共享性（树 + 表）  —— 存储模块 CRUD 专项 skill
#
# 覆盖需求点（逐字原文见 docs/REQ_MATRIX.md §1）：
#   R-16 共享 Mod 文件（"不同 TsFile 可以对应同一个 Mod 文件"）
#   R-17 命名 `<level>-<modFileNum>`、后缀名改为 mods2
#   R-18 Res 文件存储对应 Mod 文件的绝对路径
#   R-19 "Mod 文件分配的触发时机为某 TsFile 第一次接收到删除操作时"
#   R-20 "Mod 文件分配是按 TsFile 的层级进行的"
#   R-22 Entry 首字节区分 Table Deletion(0x00) / Tree Deletion(0x01)
#
# ★★ 本构建（RC7 `7c61428`）的关键事实（矩阵 §3 CR-04 + §4-B1/B3 已核实）：
#   · Mod 文件后缀 = **`.mods2`**（`ModificationFile.FILE_SUFFIX`）；V1 旧后缀才是 `.mods`。
#     **不要**用 `*.mods` 这种 glob 统计（会漏掉 `.mods2`，曾把"没造出来"误判成缺陷）。
#   · `TsFileResource.useSharedModFile = false`（**编译期常量**、无配置键、不可运行时切换）
#     ⇒ 走 `getExclusiveModFile()`：**每个 TsFile 一个独占 `<tsfile>.mods2`**。
#     因此设计文档里的 `<level>-<modFileNum>.mods2` 共享命名、`.compaction.mods2`(C_Mod)、
#     Res 记录 Mod 绝对路径（R-18/R-29 的 Res v2 布局）在本构建**不可观测**：
#     这部分只做"记录 + WARN"，**不写硬判据**。
#   · 硬编码阈值（`PartitionLevelModFileManager:36-37` 30 / 16KB）只在共享分支生效，
#     本用例不引用、不热改（阈值行为见 CR-05）。
#
# 判据（硬）：
#   ① 场景有效性：起点 3 个 TsFile / 删除前无任何 `.mods2`；
#   ② R-19：只有"被删除覆盖"的 TsFile 才有 `.mods2`，未被删除的 TsFile 一个都没有；
#   ③ 形态：独占命名 `<tsfile>.mods2`，每副本恰好 1 个（`shared=0`）；
#   ④ R-22：首字节 = 0x01（树）/ 0x00（表）；
#   ⑤ 重复删除只追加：文件数不变、字节数增加；
#   ⑥ 数据面：被删设备 0 行、未删设备行数/指纹不变、三副本一致；
#   ⑦ 双信号：`[Deletion] Deletion … is written into … mod files` 行数增加 **且** 文件面变化。
# 判据（软，只 WARN）：出现共享命名/`.compaction.mods2`（= 构建可能已打开共享方案）、
#   Res 里出现 mods2 路径（R-18 观测面异常）、R-20 的"层级"在独占形态下不可观测。
#
# 用法： bash cases/common/cr_mod_shape.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：10~15 min（无重启）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_mod_shape_${DATA_CONSENSUS}"

DB=root.crmods          # 树模型库
TDB=crmodsb             # 表模型库（表模型库名不带 root. 前缀，与 compaction skill 表模型用例一致）
TB=t1
ROWS=${CR_MOD_ROWS:-100}
WIN=${CR_MOD_WIN_SEC:-120}

# ===========================================================================
# Mod 文件观测 helper（只用 lib 已有能力：sshx / sq / sqt / data_rows / cmp_tbl_rows …）
#   按"路径中的库目录名"精确匹配（表模型内部目录可能带 root. 前缀，region 目录可能是 <db>-<n>），
#   避免用 `*/$db/*` 这类glob 因命名差异漏匹配、也避免子串误匹配到别的库。
# ===========================================================================
crm_find(){ local h=$1 db=$2 suf=$3
  sshx "$h" "find $DB_DIR/data/datanode/data -name '*$suf' -printf '%p|%s\n' 2>/dev/null" 2>/dev/null \
  | awk -F'|' -v db="$db" '{n=split($1,a,"/"); for(i=1;i<=n;i++){c=a[i]; if(c==db||c=="root."db||index(c,db"-")==1||index(c,"root."db"-")==1){print a[n]"|"$2; next}}}'; }
crm_mods(){  crm_find "$1" "$2" '.mods2' | sort; }              # 含共享命名 / .compaction.mods2 / 独占命名
crm_excl(){  crm_find "$1" "$2" '.tsfile.mods2' | sort; }       # 仅独占命名 <tsfile>.mods2
crm_tslist(){ crm_find "$1" "$2" '.tsfile' | sort; }            # <basename>|<字节>
crm_cnt(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | wc -l | tr -dc '0-9'; }
crm_cnt_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_cnt "$h" "$db") )); done; echo "$s"; }
crm_cnts(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(crm_cnt "$h" "$db") "; done; echo "$out"; }
crm_ts_cnt(){ printf '%s\n' "$(crm_tslist "$1" "$2")" | sed '/^$/d' | wc -l | tr -dc '0-9'; }
crm_ts_cnts(){ local db=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(crm_ts_cnt "$h" "$db") "; done; echo "$out"; }
crm_bytes(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | awk -F'|' '{s+=$2} END{print s+0}'; }
crm_bytes_sum(){ local db=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_bytes "$h" "$db") )); done; echo "$s"; }
# 被"独占 Mod 文件"引用的 TsFile 名（去掉 .mods2 后缀），空格分隔
crm_owners(){ crm_excl "$1" "$2" | sed 's/\.mods2|.*$//' | tr '\n' ' ' | sed 's/ *$//'; }
crm_tsnames(){ crm_tslist "$1" "$2" | sed 's/|[0-9]*$//' | tr '\n' ' ' | sed 's/ *$//'; }   # 保留 .tsfile 后缀（crm_byte/crm_exists 都按完整名查）
# 命名形态分类（本构建期望 exclusive=N、shared=0、cmod=0）
crm_kinds(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | awk -F'|' '{n=$1}
    n ~ /\.compaction\.mods2$/   {c++; next}
    n ~ /\.tsfile\.mods2$/       {e++; next}
    n ~ /^[0-9]+-[0-9]+\.mods2$/ {s++; next}
    {o++}
    END{printf "exclusive=%d shared=%d cmod=%d other=%d", e+0, s+0, c+0, o+0}'; }
crm_kind_of(){ printf '%s' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }
# 共享命名 / C_Mod 出现即"构建变更"：只记录 + WARN，不判 FAIL（矩阵 §4-B1/B4）
crm_shape_note(){ local db=$1 k e s c
  k=$(crm_kinds "${DN[0]}" "$db")
  e=$(crm_kind_of "$k" exclusive); s=$(crm_kind_of "$k" shared); c=$(crm_kind_of "$k" cmod)
  log "  [$db] Mod 文件命名形态：$k（exclusive=${e:-0} shared=${s:-0} cmod=${c:-0}）"
  if [ "${s:-0}" -eq 0 ] && [ "${c:-0}" -eq 0 ]; then
    pass "[$db] 形态符合本构建（独占 <tsfile>.mods2；无共享命名、无 .compaction.mods2）"
  else
    warn "[$db] 出现共享命名/.compaction.mods2（$k）⇒ 构建可能已打开共享 Mod 文件方案；本用例按独占形态写下的判据请人工复核"
  fi; }
# 某独占 Mod 文件的首字节（十六进制小写）；文件不存在 → NA
crm_byte(){ local h=$1 owner=$2 v
  v=$(sshx "$h" "f=\$(find $DB_DIR/data/datanode/data -name '$owner.mods2' 2>/dev/null | head -1); if [ -n \"\$f\" ]; then od -An -tx1 -N1 \"\$f\" | tr -d ' \n'; else echo NA; fi" 2>/dev/null | tr -dc '0-9a-f')
  echo "${v:-NA}"; }
crm_hex16(){ local h=$1 owner=$2
  sshx "$h" "f=\$(find $DB_DIR/data/datanode/data -name '$owner.mods2' 2>/dev/null | head -1); [ -n \"\$f\" ] && od -An -tx1 -N16 \"\$f\" | tr -s ' '" 2>/dev/null; }
# 该库 .resource 文件里是否出现 "mods2"（R-18 观测面；非共享形态源码写 null ⇒ 期望 0）
crm_res_ref(){ local h=$1 db=$2 n
  n=$(sshx "$h" "n=0; for f in \$(find $DB_DIR/data/datanode/data -name '*.resource' 2>/dev/null | grep -E '/($db|root\.$db)(-|/)'); do c=\$(grep -ac mods2 \"\$f\" 2>/dev/null); n=\$(( n + \${c:-0} )); done; echo \$n" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# 日志面：`[Deletion] Deletion … is written into … mod files`
crm_logcnt(){ local h=$1 pat=$2 n
  n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -F '$pat' | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${n:-0}"; }
crm_logsum(){ local pat=$1 h s=0; for h in "${DN[@]}"; do s=$(( s + $(crm_logcnt "$h" "$pat") )); done; echo "$s"; }
# 行数（树：原始查询数行 —— 设备级通配上的聚合会退化成 Empty set，不能用聚合）
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
# 等各副本 TsFile 数 == want（用精确库名匹配；不用 cmp_lay —— 它按 '*/<db>/*' 匹配，表模型目录可能带前缀）
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
# 等各副本 .mods2 数都 == want（DELETE 走共识，副本可能滞后 ⇒ 先等再判，避免假 FAIL）
crm_wait_cnt(){ local db=$1 want=$2 t=${3:-90} h n ok deadline
  deadline=$(( $(date +%s) + t ))
  while (( $(date +%s) < deadline )); do
    ok=1
    for h in "${DN[@]}"; do n=$(crm_cnt "$h" "$db"); [ "${n:-0}" = "$want" ] || ok=0; done
    [ "$ok" = 1 ] && return 0
    sleep 3
  done
  return 1; }
# 写单设备一批（时间戳严格递增 ⇒ 落 sequence/）
crm_write_dev(){ local db=$1 dev=$2 rows=$3 base=$4 b=${5:-1} k vals=""
  for ((k=0;k<rows;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.$dev(time,s1) values ${vals%,};" >/dev/null || return 1
  sq "flush;" >/dev/null; }
# 执行 SQL 并捕获报错（注意：成功的语句也可能打印 `Msg: …successfully`，不能用 Msg 判错）
crm_sql(){ local out; out=$(sq "$1" 2>&1)
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException|Exception'; then
    echo "ERR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  return 0; }
crm_sqlt(){ local out; out=$(sqt "$1" 2>&1)
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException|Exception'; then
    echo "ERR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  return 0; }

# ===========================================================================
log "--- 集群准备（三类合并全关：文件形态可观测；参数 $CMP_EXTRA_WRITE）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"
cmp_compaction_off

# ---------------------------------------------------------------------------
log "--- ① 树模型：3 个设备各一批（每批 $ROWS 行）⇒ 3 个 seq TsFile ---"
cmp_make_tree_db "$DB" 3
BASE=$(( ($(date +%s) - 600) * 1000 ))
for i in 1 2 3; do
  crm_write_dev "$DB" "d$i" "$ROWS" "$(( BASE + i * 10000 ))" "$i" || fail "写入 $DB.d$i 失败"
  cmp_wait_close "$DB" "$i" 90 >/dev/null || warn "  d$i 批 close 事件未达 $i（$(ttl_close_snapshot "$DB")）"
  crm_wait_ts "$DB" "$i" 150 >/dev/null || warn "  d$i 批后 TsFile 数=$(crm_ts_cnts "$DB")（期望各副本 $i）"
done
TS0=$(crm_ts_cnt "${DN[0]}" "$DB")
log "  起点：TsFile=$(crm_ts_cnts "$DB") mods2=$(crm_cnts "$DB") 行数 d1=$(crm_rows_t "$DB.d1" s1) d2=$(crm_rows_t "$DB.d2" s1) d3=$(crm_rows_t "$DB.d3" s1)"
[ "${TS0:-0}" -ge 3 ] && pass "场景有效：起点 TsFile=$TS0（≥3，能区分'删过/未删过'的文件）" \
  || fail "场景无效：起点 TsFile=$TS0（<3）"
[ "$(crm_cnt_sum "$DB")" -eq 0 ] && pass "删除前该库无任何 .mods2（R-19 的基线成立）" \
  || fail "场景无效：删除前已存在 .mods2（$(crm_mods "${DN[0]}" "$DB" | tr '\n' ' ')）"
[ "$(crm_rows_t "$DB.d1" s1)" = "$ROWS" ] && pass "d1 写入 $ROWS 行可见" || fail "场景无效：d1 行数=$(crm_rows_t "$DB.d1" s1)（期望 $ROWS）"

mapfile -t TL < <(crm_tsnames "${DN[0]}" "$DB" | tr ' ' '\n' | sed '/^$/d' | sort)
F1=${TL[0]:-}; F2=${TL[1]:-}; F3=${TL[2]:-}
log "  本副本 TsFile（按名排序=按 flush 时间排序）：F1=$F1 F2=$F2 F3=$F3"
[ -n "$F1" ] && [ -n "$F2" ] && [ -n "$F3" ] && pass "已取到 3 个 TsFile 名（F1/F2/F3，供'首次删除才分配'判据定位）" \
  || fail "场景无效：未能取到 3 个 TsFile 名（$(crm_tsnames "${DN[0]}" "$DB")）"
D2FP0=$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")

# ---------------------------------------------------------------------------
log "--- ② R-19/R-22：只删 d1 ⇒ 只有 d1 所在 TsFile 分配独占 .mods2（首字节期望 0x01）---"
T1=$(( BASE + 10000 + (ROWS - 1) * 10 ))
L0=$(crm_logsum 'is written into'); LD0=$(crm_logsum '[Deletion]'); B0=$(crm_bytes_sum "$DB")
crm_sql "delete from $DB.d1.** where time <= $T1;" >/dev/null || fail "DELETE d1 语句报错"
GOT=$(crm_wait_rows_t "$DB.d1" s1 0 90) || true
assert_eq "删除后 d1 行数（原始查询数行）" "$GOT" "0"
L1=$(crm_logsum 'is written into'); LD1=$(crm_logsum '[Deletion]')
if [ "${L1:-0}" -gt "${L0:-0}" ]; then pass "日志面信号：'is written into … mod files' $L0 → $L1（+$(( L1 - L0 ))）"
elif [ "${LD1:-0}" -gt "${LD0:-0}" ]; then pass "日志面信号：[Deletion] 行数 $LD0 → $LD1（严格文案未增，记录）"
else fail "双信号缺失：删除后既无 'is written into … mod files' 也无新的 [Deletion] 日志行"; fi
crm_wait_cnt "$DB" 1 90 >/dev/null || warn "  .mods2 数未在 90s 内三副本统一为 1（$(crm_cnts "$DB")）——删除可能仍在同步"
OWN=$(crm_owners "${DN[0]}" "$DB")
log "  各副本 .mods2 数=$(crm_cnts "$DB") 宿主TsFile=[$OWN] 清单=$(crm_mods "${DN[0]}" "$DB" | tr '\n' ' ')"
crm_shape_note "$DB"
for h in "${DN[@]}"; do
  n=$(crm_cnt "$h" "$DB")
  [ "${n:-0}" -eq 1 ] && pass "$h 被删除影响的 TsFile 恰好 1 个独占 .mods2" \
    || fail "$h .mods2 数=$n（期望 1；0=删除没落到 Mod 文件 ⇒ 场景未成立，>1=形态异常）"
done
printf '%s' "$OWN" | grep -qF "$F1" && pass "R-19：d1 所在 TsFile 已分配 Mod 文件（$F1.mods2）" \
  || fail "R-19：d1 所在 TsFile（$F1）没有 .mods2，实际宿主=[$OWN]"
for f in "$F2" "$F3"; do
  [ -n "$f" ] || continue
  printf '%s' "$OWN" | grep -qF "$f" && fail "R-19 违反：未被删除覆盖的 TsFile $f 也被分配了 Mod 文件" \
    || pass "R-19：未被删除覆盖的 TsFile $f 无 Mod 文件"
done
SZ=$(crm_excl "${DN[0]}" "$DB" | awk -F'|' '{s+=$2} END{print s+0}')
[ "${SZ:-0}" -gt 0 ] && pass "Mod 文件非空（${SZ}B，删除记录确实写入）" || fail "场景未成立：Mod 文件字节数为 0"
BYTE=$(crm_byte "${DN[0]}" "$F1")
log "  $F1.mods2 首字节=$BYTE 前16字节=$(crm_hex16 "${DN[0]}" "$F1" | tr -s ' ')"
assert_eq "R-22：树模型 Entry 首字节（TREE_DELETION=0x01）" "$BYTE" "01"
RESREF=$(crm_res_ref "${DN[0]}" "$DB")
log "  Res 文件里 'mods2' 出现次数=$RESREF（非共享形态源码写 null）"
[ "${RESREF:-0}" -eq 0 ] && pass "记录：非共享形态下 Res 未记录 Mod 路径（R-18/R-29 的 Res v2 布局不可观测）" \
  || warn "Res 里出现 mods2 路径（$RESREF 处）——与源码非共享形态不符，请人工确认 R-18 观测面"

# ---------------------------------------------------------------------------
log "--- ③ R-19：第三个（未删过）TsFile 首次删除前无 Mod 文件，删除后才分配 ---"
T3=$(( BASE + 30000 + (ROWS - 1) * 10 ))
crm_sql "delete from $DB.d3.** where time <= $T3;" >/dev/null || fail "DELETE d3 语句报错"
GOT3=$(crm_wait_rows_t "$DB.d3" s1 0 90) || true
assert_eq "删除后 d3 行数" "$GOT3" "0"
OWN3=$(crm_owners "${DN[0]}" "$DB")
log "  宿主TsFile=[$OWN3] 各副本 .mods2 数=$(crm_cnts "$DB")"
printf '%s' "$OWN3" | grep -qF "$F3" && pass "第三个 TsFile 首次删除后才有 .mods2（$F3.mods2）" \
  || fail "第三个 TsFile（$F3）删除后仍无 .mods2，宿主=[$OWN3]"
crm_wait_cnt "$DB" 2 90 >/dev/null || warn "  .mods2 数未在 90s 内三副本统一为 2（$(crm_cnts "$DB")）"
assert_eq "此时该库独占 .mods2 数（${DN[0]}）" "$(crm_cnt "${DN[0]}" "$DB")" "2"

# ---------------------------------------------------------------------------
log "--- ④ 重复删除只追加：文件数不变 + 字节数增加 ---"
C0=$(crm_cnt_sum "$DB"); B1=$(crm_bytes_sum "$DB")
crm_sql "delete from $DB.d1.** where time <= $T1;" >/dev/null || fail "重放 DELETE d1 报错"
sleep 2
C1=$(crm_cnt_sum "$DB"); B2=$(crm_bytes_sum "$DB")
log "  重放删除：.mods2 数 $C0 → $C1；字节数 $B1 → $B2"
assert_eq "重放删除不新建 Mod 文件（文件数不变）" "$C1" "$C0"
[ "${B2:-0}" -gt "${B1:-0}" ] && pass "重放删除追加了删除记录（字节 +$(( B2 - B1 ))，entry 追加语义）" \
  || fail "重放删除后 Mod 文件字节数未增加（$B1 → $B2）"

# ---------------------------------------------------------------------------
log "--- ⑤ 数据面：未被删除的 d2 行数/指纹不变；三副本一致 ---"
assert_eq "d2 行数（未删除）" "$(crm_wait_rows_t "$DB.d2" s1 "$ROWS" 60)" "$ROWS"
cmp_assert_same "删除 d1/d3 后 d2 全序列指纹" "$D2FP0" "$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")"
for h in "${DN[@]}"; do
  r=$(sq_node "$h" "select s1 from $DB.d2 order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9')
  [ "${r:-0}" = "$ROWS" ] && pass "$h 上 d2 行数=$r（与主节点一致）" || fail "$h 上 d2 行数=$r（期望 $ROWS，副本不一致）"
done
warn "R-20（按 TsFile 层级分配 Mod 文件）在独占形态下退化为『按 TsFile 分配』：文件名不体现层级（层级只在共享命名 <level>-<n>.mods2 里可见）⇒ 记录不硬判"

# ---------------------------------------------------------------------------
log "--- ⑥ 表模型：部分覆盖同一 TsFile ⇒ 独占 .mods2，首字节期望 0x00 ---"
cmp_make_table_db "$TDB" "$TB"
for i in 1 2; do
  cmp_write_table_batch "$TDB" "$TB" 1 "$ROWS" "$i" "$(( BASE + i * 10000 ))"
  cmp_wait_close "$TDB" "$i" 90 >/dev/null || warn "  [$TDB] 批$i close 事件未达 $i"
  crm_wait_ts "$TDB" "$i" 150 >/dev/null || warn "  [$TDB] 批$i 后 TsFile=$(crm_ts_cnts "$TDB")"
done
TR0=$(cmp_tbl_rows "select v from $TDB.$TB order by time;")
log "  [$TDB] TsFile=$(crm_ts_cnts "$TDB") 行数=$TR0 mods2=$(crm_cnts "$TDB")"
assert_eq "表模型起点行数（$ROWS × 2 批）" "$TR0" "$(( ROWS * 2 ))"
assert_eq "表模型删除前无 .mods2" "$(crm_cnt_sum "$TDB")" "0"
mapfile -t TL2 < <(crm_tsnames "${DN[0]}" "$TDB" | tr ' ' '\n' | sed '/^$/d' | sort)
TF1=${TL2[0]:-}; TF2=${TL2[1]:-}
MID=$(( BASE + 10000 + 49 * 10 ))     # 只覆盖 file1 的前半段（部分覆盖 ⇒ 走 Mod 记录路径）
L2=$(crm_logsum 'is written into')
crm_sqlt "delete from $TDB.$TB where time <= $MID;" >/dev/null || fail "表模型 DELETE 报错"
TGOT=$(crm_wait_rows_b "select v from $TDB.$TB order by time;" "$(( ROWS + 50 ))" 90) || true
assert_eq "表模型部分删除后行数" "$TGOT" "$(( ROWS + 50 ))"
L3=$(crm_logsum 'is written into')
[ "${L3:-0}" -gt "${L2:-0}" ] && pass "表模型删除写 Mod 文件的日志信号 $L2 → $L3" \
  || fail "表模型删除后无 'is written into … mod files' 日志行（双信号缺失）"
crm_wait_cnt "$TDB" 1 90 >/dev/null || warn "  [$TDB] .mods2 数未在 90s 内三副本统一为 1（$(crm_cnts "$TDB")）"
TOWN=$(crm_owners "${DN[0]}" "$TDB")
log "  [$TDB] .mods2 数=$(crm_cnts "$TDB") 宿主TsFile=[$TOWN]"
crm_shape_note "$TDB"
assert_eq "表模型被删除影响的 TsFile 独占 .mods2 数（${DN[0]}）" "$(crm_cnt "${DN[0]}" "$TDB")" "1"
printf '%s' "$TOWN" | grep -qF "$TF1" && pass "表模型 d1 所在 TsFile 已分配 Mod 文件（$TF1.mods2）" \
  || fail "表模型 $TF1 没有 .mods2，实际宿主=[$TOWN]"
printf '%s' "$TOWN" | grep -qF "$TF2" && fail "表模型未被删除覆盖的 TsFile $TF2 也被分配了 Mod 文件" \
  || pass "表模型未被删除覆盖的 TsFile $TF2 无 Mod 文件"
TBYTE=$(crm_byte "${DN[0]}" "$TF1")
log "  $TF1.mods2 首字节=$TBYTE 前16字节=$(crm_hex16 "${DN[0]}" "$TF1" | tr -s ' ')"
assert_eq "R-22：表模型 Entry 首字节（TABLE_DELETION=0x00）" "$TBYTE" "00"

# ---------------------------------------------------------------------------
log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.d2 order by time;" tree
cmp_case_finish "" tree ""
