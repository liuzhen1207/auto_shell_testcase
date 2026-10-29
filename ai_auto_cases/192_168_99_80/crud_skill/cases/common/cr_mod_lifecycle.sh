#!/bin/bash
# ============================================================================
# CR-09 旧 Mod 兼容 + Res 变更 + 重启恢复 + Mod 文件生命周期（树模型）
#       —— 存储模块 CRUD 专项 skill
#
# 覆盖需求点（逐字原文见 docs/REQ_MATRIX.md §1）：
#   R-28 "需要在 TsFileResource 中增加一个内存字段 oldModificationFile 用于指向可能存在的旧
#         Mod 文件" / "读取旧的 Mod 文件时，所有删除操作记录均会被返回"
#   R-29 Res 文件格式变更（版本号 1→2、modFilePath 位置、追加指针、记录 Mod 文件长度）
#   R-30 "如果一个 DataRegion 在异步恢复完成前接收到删除请求，则抛出一个异常"
#   R-31 "每个 ModificationFile 中使用一个 Set<TsFileResource> 指向引用其的 TsFileResource"
#   R-32 "将所有不存在于 partitionModFiles 中的 .mods2 文件删除" / 无引用 Mod 文件被删除
#
# ★★ 本构建（RC7 `7c61428`）的关键事实（矩阵 §4-B1/B3/B12 已核实）：
#   · Mod 文件后缀 = **`.mods2`**；V1 旧 Mod 文件后缀 = **`.mods`**（文本格式
#     `DELETION,<序列路径>,<offset>,<start>,<end>`，见 LocalTextModificationAccessor）。
#     统计文件时**不要**用 `*.mods` 这种 glob（会漏 `.mods2`）。
#   · V1→V2 升级是**真实存在且可观测**的路径：DataRegion 恢复时对"有 .resource 但没有
#     `<tsfile>.mods2`"的 TsFile 调用 `TsFileResource.upgradeModFile()`（异步线程池）：
#     把旧 `.mods` 的每条 Deletion 写成 `.mods2` 的 TreeDeletionEntry，然后**删掉旧 `.mods`**。
#     ⇒ R-28 的"旧 Mod 兼容"本用例**硬断言**（升级产物 + 删除语义生效 + 旧文件消失）。
#   · `useSharedModFile = false`（编译期常量）⇒ `.compaction.mods2`(C_Mod)、`<level>-<n>.mods2`
#     共享命名、Res 记录 Mod 绝对路径（R-29 的 Res v2 布局）**不可观测**：只记录 + WARN，不写硬判据。
#   · R-30 的窗口在 3C3D 小数据量下难以命中（矩阵 §4-B12）；且源码里 `getExclusiveModFile()`
#     是 `exclusiveModFileFuture.get()` **阻塞等待**而不是抛异常 ⇒ 抓不到就如实记 WARN，不判 FAIL。
#   · R-32 前半句（扫描时间分区目录、删除不属于 partitionModFiles 的 .mods2）在 RC7 源码里
#     **没有对应实现**：`ModFileManagement` 接口只有 recover/allocateFor/releaseFor/addReference
#     （无目录扫描方法）。⇒ 孤儿清理**只记录 + WARN**，不判 FAIL；
#     R-32 后半句（引用归零 ⇒ 释放/删除）**可观测**，本用例硬断言。
#
# 判据（硬）：
#   ① 场景有效性：2 个 seq TsFile、`.resource` 齐全、删除前无 `.mods2`；
#   ② R-28：注入的 V1 `.mods` 在重启后被升级成 `<tsfile>.mods2`（首字节 0x01），旧 `.mods` 消失，
#      且旧删除记录**真的生效**（行数下降）；
#   ③ 持久性：重启前已存在的 `<tsfile>.mods2` 仍在、字节数与 md5 **完全不变**；
#   ④ 数据面：重启前后行数/指纹一致、三副本一致；孤儿注入不破坏数据；
#   ⑤ R-31/R-32（后半）：带 Mod 的源 TsFile 被合并移除后，其 `.mods2` **必须同时被删除**
#      （若残留即 FAIL：文件泄漏）；被删数据合并后**不得复活**；
#   ⑥ 双信号：恢复/升级相关文件面变化 + 行数变化；（合并段）finishes 行数 + TsFile 数下降。
# 判据（软，只 WARN/记录）：R-29 的 Res 二进制布局（VERSION_NUMBER 在 RC7 仍是 1）、
#   R-30 的恢复窗口未命中、R-32 的孤儿 `.mods2` 目录扫描未实现、共享命名/`.compaction.mods2` 出现。
#
# 用法： bash cases/common/cr_mod_lifecycle.sh [--consensus IoTConsensus|IoTConsensusV2]
# 预估耗时：15~25 min（含 1 次整集群重启 + 1 次单 DN 重启 + 1 轮合并）
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题）：
#   ① 三副本的 TsFile **文件名各不相同**（前缀是该副本自己的 flush 时间戳）。首轮拿
#      `DN[0]` 的两个文件名去 78/79 上找 ⇒ `.resource` 报 0/0、`取不到 … 的路径`、V1 旧 Mod
#      只注入到 77 ⇒ 78/79 上 d2 没被删（`旧 .mod 未被读取/升级` / `d2 行数 100 期望 0` 等连带 FAIL）。
#      现在一律"按副本各自取"：`crm_tsn`（第 n 个）/`crm_ts_dev`（按 .resource 里的设备路径找，
#      找不到退回位置序），并对 `.resource` 做**短轮询**（flush 收尾先写 TsFile 再写 .resource）。
#   ② `cmp_wait_merge` 内部用 `cmp_all_sum`（三副本合计）比文件数，而首轮传的是**单副本**计数
#      ⇒ 基线 3 对实际 6/9，"合并未推进"是**单位不一致**导致的假 FAIL。现两个口径分开记。
#   ③ 三副本升级/消失判定全部改成逐副本（`crm_wait_upgrade_all` / `crm_gone_all`）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_mod_lifecycle_${DATA_CONSENSUS}"

DB=root.crlife
ROWS=${CR_MOD_ROWS:-100}
WIN=${CR_MOD_WIN_SEC:-180}

# ===========================================================================
# Mod 文件 / 生命周期观测 helper（与 CR-04/CR-05 同一套）
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
crm_bytes_sum(){ local db=$1 h s=0 n; for h in "${DN[@]}"; do n=$(printf '%s\n' "$(crm_mods "$h" "$db")" | sed '/^$/d' | awk -F'|' '{s+=$2} END{print s+0}'); s=$(( s + ${n:-0} )); done; echo "$s"; }
crm_owners(){ crm_excl "$1" "$2" | sed 's/\.mods2|.*$//' | tr '\n' ' ' | sed 's/ *$//'; }
crm_tsnames(){ crm_tslist "$1" "$2" | sed 's/|[0-9]*$//' | tr '\n' ' ' | sed 's/ *$//'; }   # 保留 .tsfile 后缀（crm_gone/crm_byte/crm_exists 都按完整名查）
# ★ 某个副本上第 n 个 TsFile 名（**必须按节点各自取**）
#   文件名前缀是**该副本自己**的 flush 时间戳（`<flushTime>-<n>-<level>-<seq>.tsfile`）⇒ 三副本文件名
#   **互不相同**。RC8 首轮 CR-09 直接拿 DN[0] 的两个名字去 78/79 上找 ⇒ `.resource` 报 0/0、
#   `取不到 … 的路径`、V1 旧 Mod 只注入到 77、d2 也因此没被删掉（连带 6 条 FAIL）。
crm_tsn(){ local h=$1 db=$2 idx=$3
  crm_tsnames "$h" "$db" | tr ' ' '\n' | sed '/^$/d' | sort | sed -n "${idx}p"; }
# 承载某设备的 TsFile 名：优先按 `.resource` 里能 grep 到的设备路径找，找不到再退回"第 idx 个"
crm_ts_dev(){ local h=$1 db=$2 dev=$3 idx=${4:-1} n
  n=$(sshx "$h" "for r in \$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.resource' 2>/dev/null); do grep -qa '$dev' \"\$r\" 2>/dev/null && { b=\$(basename \"\$r\"); echo \"\${b%.resource}\"; }; done | sort -u" 2>/dev/null | tr -d '\r')
  if [ -n "$n" ]; then printf '%s' "$(printf '%s\n' "$n" | sed -n "${idx}p")"
  else crm_tsn "$h" "$db" "$idx"; fi; }
# 等某节点上 d1/d2 两个 TsFile 的 `.resource` 都出现（flush 收尾先写 TsFile 再写 .resource，有秒级窗口）
#   回显 "f1 f2"；0=都齐了
crm_wait_res(){ local h=$1 db=$2 t=${3:-90} dl f1 f2
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    f1=$(crm_ts_dev "$h" "$db" "$db.d1" 1); f2=$(crm_ts_dev "$h" "$db" "$db.d2" 2)
    if [ -n "$f1" ] && [ -n "$f2" ] \
       && [ "$(crm_exists "$h" "$f1.resource")" -gt 0 ] && [ "$(crm_exists "$h" "$f2.resource")" -gt 0 ]; then
      printf '%s %s' "$f1" "$f2"; return 0
    fi
    sq "flush;" >/dev/null 2>&1
    sleep 3
  done
  printf '%s %s' "${f1:-}" "${f2:-}"; return 1; }
crm_kinds(){ printf '%s\n' "$(crm_mods "$1" "$2")" | sed '/^$/d' | awk -F'|' '{n=$1}
    n ~ /\.compaction\.mods2$/   {c++; next}
    n ~ /\.tsfile\.mods2$/       {e++; next}
    n ~ /^[0-9]+-[0-9]+\.mods2$/ {s++; next}
    {o++}
    END{printf "exclusive=%d shared=%d cmod=%d other=%d", e+0, s+0, c+0, o+0}'; }
crm_kind_of(){ printf '%s' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }
# 任意文件（TsFile / .mods / .mods2 / .resource）在某节点上的绝对路径
crm_path(){ sshx "$1" "find $DB_DIR/data/datanode/data -name '$2' 2>/dev/null | head -1" 2>/dev/null | tr -d '\r'; }
# 某文件在某节点上的出现次数（精确文件名匹配）
crm_exists(){ local n; n=$(sshx "$1" "find $DB_DIR/data/datanode/data -name '$2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${n:-0}"; }
crm_md5(){ sshx "$1" "f=\$(find $DB_DIR/data/datanode/data -name '$2' 2>/dev/null | head -1); [ -n \"\$f\" ] && md5sum \"\$f\" | cut -d' ' -f1" 2>/dev/null | tr -d '\r\n '; }
crm_size(){ sshx "$1" "f=\$(find $DB_DIR/data/datanode/data -name '$2' 2>/dev/null | head -1); [ -n \"\$f\" ] && stat -c %s \"\$f\"" 2>/dev/null | tr -dc '0-9'; }
crm_byte(){ local v
  v=$(sshx "$1" "f=\$(find $DB_DIR/data/datanode/data -name '$2' 2>/dev/null | head -1); if [ -n \"\$f\" ]; then od -An -tx1 -N1 \"\$f\" | tr -d ' \n'; else echo NA; fi" 2>/dev/null | tr -dc '0-9a-f')
  echo "${v:-NA}"; }
# 造 V1 旧 Mod 文件（文本格式，见 LocalTextModificationAccessor：DELETION,path,offset,start,end）
crm_write_v1mods(){ local h=$1 tspath=$2 series=$3 start=$4 end=$5
  sshx "$h" "printf 'DELETION,%s,%s,%s,%s\n' '$series' 0 '$start' '$end' > '$tspath.mods'" 2>/dev/null
  crm_exists "$h" "$(basename "$tspath").mods"; }
crm_mkfile(){ local h=$1 path=$2 bytes=$3
  sshx "$h" "head -c $bytes /dev/zero > '$path'" 2>/dev/null; }
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
crm_write_dev(){ local db=$1 dev=$2 rows=$3 base=$4 b=${5:-1} k vals=""
  for ((k=0;k<rows;k++)); do vals="$vals($(( base + k*10 )),$((k+b))),"; done
  sq "insert into $db.$dev(time,s1) values ${vals%,};" >/dev/null || return 1
  sq "flush;" >/dev/null; }
crm_sql(){ local out; out=$(sq "$1" 2>&1)
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException|Exception'; then
    echo "ERR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  return 0; }
crm_firsterr(){ printf '%s' "$1" | grep -oE '(IoTDBSQLException|Exception)[^|]*' | head -1 | cut -c1-200; }
# 单 DN 重启（kill -9 + 起；数据目录不动 ⇒ 触发 DataRegion 恢复路径）
crm_restart_dn(){ local h=$1
  log "  重启 DataNode $h（stop -f → start，数据不清）"
  sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" || true
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  $h 未进入 notrunning"
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h##*.}.log 2>&1 </dev/null &" || true
  wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "  $h 未恢复 Running"; }
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
# 等"V1 .mods 升级完成"：**逐副本各自的 d2 TsFile** 都出现 <tsfile>.mods2 且旧 .mods 消失
crm_wait_upgrade_all(){ local db=$1 t=${2:-300} h f2 n2 n1 ok dl
  dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    ok=1
    for h in "${DN[@]}"; do
      f2=${CRML_F2[$h]:-}
      [ -n "$f2" ] || { ok=0; continue; }
      n2=$(crm_exists "$h" "$f2.mods2"); n1=$(crm_exists "$h" "$f2.mods")
      [ "${n2:-0}" -gt 0 ] && [ "${n1:-0}" -eq 0 ] || ok=0
    done
    [ "$ok" = 1 ] && return 0
    sleep 3
  done
  return 1; }
# 这些 TsFile 名是否已在所有副本上消失（1=全部消失）
crm_gone(){ local names=$1 h f g=1
  for h in "${DN[@]}"; do for f in $names; do [ "$(crm_exists "$h" "$f")" -gt 0 ] && g=0; done; done
  echo "$g"; }
# 逐副本的待消失集合（F1N/F2N 由调用方按**各副本自己的**文件名填好）是否都已消失（1=全部消失）
crm_gone_all(){ local i=0 h f g=1
  for h in "${DN[@]}"; do
    for f in "${F1N[$i]:-}" "${F2N[$i]:-}"; do
      [ -n "$f" ] && [ "$(crm_exists "$h" "$f")" -gt 0 ] && g=0
    done
    i=$(( i + 1 ))
  done
  echo "$g"; }

# ===========================================================================
log "--- 集群准备（三类合并全关；$CMP_EXTRA_WRITE）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
log "  实际生效：$(cmp_eff_all "${DN[0]}")"
cmp_compaction_off

# ---------------------------------------------------------------------------
log "--- ① 造数据：d1 / d2 各一批（每批 $ROWS 行）⇒ 2 个 seq TsFile ---"
cmp_make_tree_db "$DB" 3
BASE=$(( ($(date +%s) - 600) * 1000 ))
crm_write_dev "$DB" d1 "$ROWS" "$(( BASE + 10000 ))" 1 || fail "写入 $DB.d1 失败"
cmp_wait_close "$DB" 1 90 >/dev/null || warn "  d1 批 close 事件未达 1"
crm_wait_ts "$DB" 1 150 >/dev/null || warn "  d1 批后 TsFile=$(crm_ts_cnts "$DB")"
# 【RC8 第二轮修正（2026-10-20）】逐副本记下"d1 批单独落盘后"的文件清单。
#   旧实现用 `crm_ts_dev`（在 .resource 里 grep 设备路径）取 d2 的 TsFile；实测 d2 的 .resource
#   grep 不到设备名 ⇒ F2 为空 ⇒ `.resource 缺失`×3 / `取不到路径`×3 / V1 旧 Mod 只注入 0 台 ⇒ 连带 15 条 FAIL。
#   改成"d2 批落盘后**新出现的那个文件**就是 d2 的 TsFile"，完全不依赖 .resource 内容。
declare -A CRML_PRE1=()
for h in "${DN[@]}"; do CRML_PRE1[$h]=$(crm_tsnames "$h" "$DB"); done
crm_write_dev "$DB" d2 "$ROWS" "$(( BASE + 20000 ))" 2 || fail "写入 $DB.d2 失败"
cmp_wait_close "$DB" 2 90 >/dev/null || warn "  d2 批 close 事件未达 2"
crm_wait_ts "$DB" 2 150 >/dev/null || warn "  d2 批后 TsFile=$(crm_ts_cnts "$DB")"
declare -A CRML_F1=() CRML_F2=()
for h in "${DN[@]}"; do
  CRML_F1[$h]=$(printf '%s\n' "${CRML_PRE1[$h]}" | tr ' ' '\n' | sed '/^$/d' | sort | head -1)
  CRML_F2[$h]=$(for _n in $(crm_tsnames "$h" "$DB"); do case " ${CRML_PRE1[$h]} " in *" $_n "*) ;; *) printf '%s' "$_n"; break ;; esac; done)
  [ -n "${CRML_F1[$h]:-}" ] || CRML_F1[$h]=$(crm_tsn "$h" "$DB" 1)
  [ -n "${CRML_F2[$h]:-}" ] || CRML_F2[$h]=$(crm_tsn "$h" "$DB" 2)
done
log "  逐副本 TsFile 归属：$(for h in "${DN[@]}"; do printf '%s:F1=%s,F2=%s ' "${h##*.}" "${CRML_F1[$h]:-?}" "${CRML_F2[$h]:-?}"; done)"
log "  起点：TsFile=$(crm_ts_cnts "$DB") mods2=$(crm_cnts "$DB") 行数 d1=$(crm_rows_t "$DB.d1" s1) d2=$(crm_rows_t "$DB.d2" s1)"
[ "$(crm_ts_cnt "${DN[0]}" "$DB")" -ge 2 ] && pass "场景有效：起点 TsFile≥2（$(crm_ts_cnts "$DB")）" \
  || fail "场景无效：起点 TsFile=$(crm_ts_cnts "$DB")（<2）"
[ "$(crm_cnt_sum "$DB")" -eq 0 ] && pass "场景有效：删除前无任何 .mods2" \
  || fail "场景无效：删除前已存在 .mods2（$(crm_mods "${DN[0]}" "$DB" | tr '\n' ' ')）"
CRML_H0=${DN[0]}; F1=${CRML_F1[$CRML_H0]:-}; F2=${CRML_F2[$CRML_H0]:-}
log "  F1=$F1（d1，稍后做 SQL 删除）  F2=$F2（d2，稍后注入 V1 旧 Mod 文件）"
[ -n "$F1" ] && [ -n "$F2" ] && pass "已取到 2 个 TsFile 名（${DN[0]}）" || fail "场景无效：未取到 2 个 TsFile 名（$(crm_tsnames "${DN[0]}" "$DB")）"
# 逐副本校验 .resource（**按各副本自己的文件名**；短轮询等 flush 收尾把 .resource 写完）
for h in "${DN[@]}"; do
  f1h=${CRML_F1[$h]:-}; f2h=${CRML_F2[$h]:-}
  dlr=$(( $(date +%s) + 90 )); rro=1
  while (( $(date +%s) < dlr )); do
    if [ -n "$f1h" ] && [ -n "$f2h" ] \
       && [ "$(crm_exists "$h" "$f1h.resource")" -gt 0 ] && [ "$(crm_exists "$h" "$f2h.resource")" -gt 0 ]; then rro=0; break; fi
    sq "flush;" >/dev/null 2>&1; sleep 3
  done
  [ "$rro" = 0 ] && pass "$h 上两个 TsFile 的 .resource 均存在（$f1h / $f2h；V1 升级路径的前置）" \
    || fail "场景无效：$h 上缺 .resource（$f1h=$(crm_exists "$h" "$f1h.resource") / $f2h=$(crm_exists "$h" "$f2h.resource")）"
done

# ---------------------------------------------------------------------------
log "--- ② 产生一个 .mods2（SQL 删除 d1）：记录行数 / 清单 / 字节 / md5 ---"
T1=$(( BASE + 10000 + (ROWS - 1) * 10 ))
crm_sql "delete from $DB.d1.** where time <= $T1;" >/dev/null || fail "DELETE d1 报错"
assert_eq "删除后 d1 行数" "$(crm_wait_rows_t "$DB.d1" s1 0 90)" "0"
assert_eq "删除后 d2 行数（未受影响）" "$(crm_rows_t "$DB.d2" s1)" "$ROWS"
crm_wait_cnt "$DB" 1 90 >/dev/null || warn "  .mods2 数未在 90s 内三副本统一为 1（$(crm_cnts "$DB")）"
assert_eq ".mods2 数（${DN[0]}）" "$(crm_cnt "${DN[0]}" "$DB")" "1"
printf '%s' "$(crm_owners "${DN[0]}" "$DB")" | grep -qF "$F1" && pass "d1 所在 TsFile 已分配独占 Mod 文件（$F1.mods2）" \
  || fail "d1 所在 TsFile 无 .mods2（宿主=[$(crm_owners "${DN[0]}" "$DB")]）⇒ 场景未成立"
MD5_0=$(crm_md5 "${DN[0]}" "$F1.mods2"); SZ_0=$(crm_size "${DN[0]}" "$F1.mods2")
BSUM_0=$(crm_bytes_sum "$DB")
FPD1_0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time;")
log "  重启前：$F1.mods2 size=${SZ_0}B md5=$MD5_0；该库 .mods2 总字节=$BSUM_0；各副本=$(crm_cnts "$DB")"

# ---------------------------------------------------------------------------
log "--- ③ R-28：注入 V1 旧 Mod 文件（<tsfile>.mods，文本 DELETION 行）覆盖 d2 全部数据 ---"
T2S=$(( BASE + 20000 )); T2E=$(( BASE + 20000 + (ROWS - 1) * 10 ))
V1OK=1
for h in "${DN[@]}"; do
  # ⚠️ 用**该副本自己**的 d2 TsFile 名（文件名前缀是各副本自己的 flush 时间戳，三副本不同）
  f2h=${CRML_F2[$h]:-}
  P2=$(crm_path "$h" "$f2h")
  [ -n "$P2" ] || { fail "取不到 $h 上 $f2h 的路径（该副本 TsFile=$(crm_tsnames "$h" "$DB")）"; V1OK=0; continue; }
  n=$(crm_write_v1mods "$h" "$P2" "$DB.d2.s1" "$T2S" "$T2E")
  [ "${n:-0}" -gt 0 ] && pass "$h 已注入 V1 旧 Mod 文件（$f2h.mods）" || { fail "$h 注入 V1 旧 Mod 文件失败"; V1OK=0; }
done
[ "$V1OK" = 1 ] && pass "场景有效：三副本都注入了 V1 旧 Mod 文件" || fail "场景无效：V1 旧 Mod 文件未全部注入"
assert_eq "$F2 在重启前没有 .mods2（纯 V1 形态）" "$(crm_exists "${DN[0]}" "$F2.mods2")" "0"
log "  注入内容（${DN[0]}）：$(sshx "${DN[0]}" "cat \$(find $DB_DIR/data/datanode/data -name '$F2.mods' | head -1)" 2>/dev/null | tr -d '\r')"

# ---------------------------------------------------------------------------
log "--- ④ 重启集群（完整 stop → start，数据不清）---"
cmp_compaction_off
cluster_stop
cluster_start

log "--- ⑤ R-30 探针：重启后立刻下发 DELETE（范围取极小值，不覆盖任何 TsFile ⇒ 不扰动文件状态）---"
PROBE_T=1     # 早于所有数据 ⇒ canSkipDelete 全跳过（只探"恢复未完成时的删除请求"这条路径）
T_MS0=$(date +%s%3N)
POUT=$(sq "delete from $DB.d1.** where time <= $PROBE_T;" 2>&1)
T_MS1=$(date +%s%3N)
PDT=$(( T_MS1 - T_MS0 ))
if printf '%s' "$POUT" | grep -qE 'IoTDBSQLException|Exception'; then
  PERR=$(crm_firsterr "$POUT")
  if printf '%s' "$PERR" | grep -qiE 'recover|not.*(ready|finish|available)|async|unavailable'; then
    pass "R-30 命中：恢复未完成时删除返回明确异常（${PDT}ms）：$PERR"
  elif printf '%s' "$PERR" | grep -qiE 'NullPointer|NullPointerException'; then
    fail "R-30 违反：恢复窗口内的删除抛 NPE（要求是'恢复未完成'类明确异常）：$PERR"
  else
    warn "R-30 探针：删除报错但语义不明确（${PDT}ms）：$PERR ⇒ 记录，请人工确认错误码语义"
  fi
else
  warn "R-30 窗口未命中：重启后立即可正常删除（耗时 ${PDT}ms，无异常）。源码里 getExclusiveModFile() 是 exclusiveModFileFuture.get() 阻塞等待而非抛异常 ⇒ 3C3D 小数据量下难以构造（矩阵 §4-B12），如实记录不判 FAIL"
fi
assert_eq "R-30 探针未改变数据（d1 行数）" "$(crm_rows_t "$DB.d1" s1)" "0"

log "--- ⑥ R-28：等 V1→V2 升级完成（<tsfile>.mods2 出现 + 旧 .mods 被删除）并断言 ---"
# 逐副本等"**该副本自己的** d2 TsFile"的升级产物（文件名三副本不同，不能拿 DN[0] 的名字去问 78/79）
crm_wait_upgrade_all "$DB" 300 && pass "V1 旧 Mod 文件已被升级为 V2（三副本都出现 <各自 d2 TsFile>.mods2、旧 .mods 消失）"
for h in "${DN[@]}"; do
  f2h=${CRML_F2[$h]:-}
  [ -n "$f2h" ] || { fail "R-28：$h 上找不到 d2 的 TsFile"; continue; }
  n2=$(crm_exists "$h" "$f2h.mods2"); n1=$(crm_exists "$h" "$f2h.mods")
  [ "${n2:-0}" -gt 0 ] && pass "$h 上出现升级产物 $f2h.mods2" || fail "R-28：$h 上 $f2h 没有 .mods2（旧 Mod 未被读取/升级）"
  [ "${n1:-0}" -eq 0 ] && pass "$h 上旧 Mod 文件 $f2h.mods 已被删除（升级后清理）" \
    || fail "R-28：$h 上旧 Mod 文件 $f2h.mods 仍残留（升级未清理旧文件）"
done
assert_eq "R-28：旧 Mod 记录生效 ⇒ d2 行数" "$(crm_wait_rows_t "$DB.d2" s1 0 120)" "0"
assert_eq "R-28：重启后 d1 行数仍为 0" "$(crm_rows_t "$DB.d1" s1)" "0"
assert_eq "$F2.mods2 首字节（TREE_DELETION=0x01）" "$(crm_byte "${DN[0]}" "$F2.mods2")" "01"
MD5_1=$(crm_md5 "${DN[0]}" "$F1.mods2"); SZ_1=$(crm_size "${DN[0]}" "$F1.mods2")
log "  重启后：$F1.mods2 size=${SZ_1}B（原 ${SZ_0}B）md5=$MD5_1（原 $MD5_0）；各副本 .mods2=$(crm_cnts "$DB")"
[ "$(crm_exists "${DN[0]}" "$F1.mods2")" -gt 0 ] && pass "持久性：重启后 $F1.mods2 仍在" || fail "持久性：重启后 $F1.mods2 丢失"
assert_eq "持久性：$F1.mods2 字节数不变" "$SZ_1" "$SZ_0"
assert_eq "持久性：$F1.mods2 md5 不变（重启不改写既有 Mod 文件）" "$MD5_1" "$MD5_0"
cmp_assert_same "重启前后 d1 指纹" "$FPD1_0" "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time;")"
RESREF=$(sshx "${DN[0]}" "n=0; for f in \$(find $DB_DIR/data/datanode/data -name '*.resource' 2>/dev/null | grep -E '/($DB|root\.$DB)(-|/)'); do c=\$(grep -ac mods2 \"\$f\" 2>/dev/null); n=\$(( n + \${c:-0} )); done; echo \$n" 2>/dev/null | tr -dc '0-9')
log "  Res 文件里 'mods2' 出现次数=${RESREF:-0}（R-29：RC7 的 VERSION_NUMBER 仍是 1，非共享形态 Res 不记录 Mod 路径）"
[ "${RESREF:-0}" -eq 0 ] && warn "R-29 记录：Res 未记录 Mod 路径、Res 版本号仍为 1（与设计文档的 Res v2 布局不同）⇒ 二进制布局不可观测，本用例只断言语义（矩阵 §4-B3）" \
  || warn "Res 里出现 mods2 路径（${RESREF} 处）—— 与源码非共享形态不符，请人工确认 R-18/R-29 观测面"
K=$(crm_kinds "${DN[0]}" "$DB"); KS=$(crm_kind_of "$K" shared); KC=$(crm_kind_of "$K" cmod)
[ "${KS:-0}" -eq 0 ] && [ "${KC:-0}" -eq 0 ] && pass "形态仍为独占命名（$K）；无共享命名/.compaction.mods2" \
  || warn "出现共享命名/.compaction.mods2（$K）⇒ C_Mod/共享方案可能已可达，请人工复核"

# ---------------------------------------------------------------------------
log "--- ⑦ R-32（前半）：人为造孤儿 .mods2，重启 1 个 DN 后看是否被清理（记录为主）---"
PD1=$(crm_path "${DN[0]}" "$F1"); DD1=$(dirname "$PD1")
ORPH_SHARED="999-999.mods2"
ORPH_EXCL="1000000000000-9-9-9.tsfile.mods2"
for h in "${DN[@]}"; do
  PH=$(crm_path "$h" "$F1"); DH=$(dirname "$PH")
  [ -n "$DH" ] || { fail "取不到 $h 上 $F1 所在目录"; continue; }
  crm_mkfile "$h" "$DH/$ORPH_SHARED" 64
  crm_mkfile "$h" "$DH/$ORPH_EXCL" 64
done
log "  已造孤儿：$DD1/$ORPH_SHARED、$DD1/$ORPH_EXCL（各副本各 1 组）"
[ "$(crm_exists "${DN[0]}" "$ORPH_SHARED")" -gt 0 ] && [ "$(crm_exists "${DN[0]}" "$ORPH_EXCL")" -gt 0 ] \
  && pass "场景有效：${DN[0]} 上孤儿 .mods2 确实存在（重启前 ls 证据）" \
  || fail "场景无效：${DN[0]} 上孤儿文件未造出来"
crm_restart_dn "${DN[0]}"
sleep 5
O1=$(crm_exists "${DN[0]}" "$ORPH_SHARED"); O2=$(crm_exists "${DN[0]}" "$ORPH_EXCL")
log "  重启后孤儿：shared=$O1 exclusive=$O2"
if [ "${O1:-0}" -eq 0 ] && [ "${O2:-0}" -eq 0 ]; then
  pass "R-32（前半）生效：不属于任何 TsFile 的 .mods2 在恢复时被清理"
else
  warn "R-32（前半）未生效：孤儿 .mods2 仍在（shared=$O1 exclusive=$O2）。源码侧 ModFileManagement 只有 recover/allocateFor/releaseFor/addReference，没有'扫描分区目录删孤儿'的方法，且共享方案编译期关闭 ⇒ 记为实现偏差/WARN，不判 FAIL（矩阵 §4-B1）"
fi
assert_eq "孤儿注入未破坏数据（d1 行数）" "$(crm_wait_rows_t "$DB.d1" s1 0 60)" "0"
assert_eq "孤儿注入未破坏数据（d2 行数）" "$(crm_rows_t "$DB.d2" s1)" "0"
for h in "${DN[@]}"; do
  PH=$(crm_path "$h" "$F1"); DH=$(dirname "$PH")
  sshx "$h" "rm -f '$DH/$ORPH_SHARED' '$DH/$ORPH_EXCL'" 2>/dev/null
done
sleep 2
assert_eq "人工清理孤儿（${DN[0]} shared）" "$(crm_exists "${DN[0]}" "$ORPH_SHARED")" "0"
assert_eq "人工清理孤儿（${DN[0]} exclusive）" "$(crm_exists "${DN[0]}" "$ORPH_EXCL")" "0"

# ---------------------------------------------------------------------------
log "--- ⑧ R-31/R-32（后半）：无引用 Mod 文件随源 TsFile 被合并移除而删除 ---"
crm_write_dev "$DB" d3 "$ROWS" "$(( BASE + 30000 ))" 3 || fail "写入 $DB.d3 失败"
cmp_wait_close "$DB" 3 90 >/dev/null || warn "  d3 批 close 事件未达 3"
crm_wait_ts "$DB" 3 150 >/dev/null || warn "  d3 批后 TsFile=$(crm_ts_cnts "$DB")"
assert_eq "d3 行数（新鲜数据，供合并且证明被删数据不复活）" "$(crm_wait_rows_t "$DB.d3" s1 "$ROWS" 90)" "$ROWS"
FPD3_0=$(cmp_fingerprint tree "select s1 from $DB.d3 order by time;")
# ⚠️ `cmp_wait_merge` 内部用 `cmp_all_sum`（**三副本合计**）比 TsFile 数，而 `crm_ts_cnt` 是**单副本**口径
#    ⇒ RC8 首轮把 3 传进去当基线，实际却是 6/9 个文件，"合并未推进"直接假 FAIL（单位不一致）。
#    这里两个口径分开记：单副本数只用于"≥3"的场景有效性，合计口径给 cmp_wait_merge。
TS1N=$(crm_ts_cnt "${DN[0]}" "$DB"); TS1=$(cmp_all_sum "$DB"); FIN0=$(cmp_inner_finish "$DB")
MOD_OWN=$(crm_owners "${DN[0]}" "$DB")
log "  合并前：TsFile=$(crm_ts_cnts "$DB")（合计 $TS1）mods2=$(crm_cnts "$DB") 宿主=[$MOD_OWN] inner finishes=$FIN0"
[ "${TS1N:-0}" -ge 3 ] && pass "场景有效：合并前单副本 TsFile=$TS1N（≥3）" || fail "场景无效：合并前单副本 TsFile=$TS1N（<3）"
printf '%s' "$MOD_OWN" | grep -qF "$F1" && pass "R-31：$F1 仍持有 Mod 文件（合并前引用存在）" \
  || warn "$F1 在合并前已不持有 Mod 文件（宿主=[$MOD_OWN]）——记录"
# 合并会把这些"带 Mod 的源 TsFile"吃掉 ⇒ 先按**各副本自己的**文件名记下待消失集合
F1N=(); F2N=()
i=0
for h in "${DN[@]}"; do
  F1N[$i]=${CRML_F1[$h]:-}
  F2N[$i]=${CRML_F2[$h]:-}
  i=$(( i + 1 ))
done
log "  待消失集合（逐副本，共 $i 个副本）：${F1N[*]} | ${F2N[*]}"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$FIN0" "$TS1" "$WIN"); then pass "合并已推进（$RES）"
else fail "合并未推进（$RES，窗口 ${WIN}s）⇒ 场景未成立"; fi
GONE=$(crm_gone_all)
deadline=$(( $(date +%s) + 180 ))
while [ "${GONE:-0}" -eq 0 ] && (( $(date +%s) < deadline )); do sleep 5; GONE=$(crm_gone_all); done
log "  合并后：TsFile=$(crm_ts_cnts "$DB") mods2=$(crm_cnts "$DB") 带 Mod 的源 TsFile 已消失=$GONE"
if [ "${GONE:-0}" -eq 1 ]; then
  pass "带 Mod 的源 TsFile（逐副本 ${F1N[*]} / ${F2N[*]}）已被合并移除"
  for f in "$F1" "$F2"; do
    [ "$(crm_exists "${DN[0]}" "$f.mods2")" -eq 0 ] && pass "R-32（后半）：$f 的 .mods2 随引用归零被删除" \
      || fail "R-32（后半）违反：源 TsFile $f 已被合并移除，但 $f.mods2 仍残留在磁盘（Mod 文件泄漏）"
  done
else
  warn "窗口内未看到带 Mod 的源 TsFile 被合并移除（TsFile=$(crm_ts_cnts "$DB")，宿主=[$(crm_owners "${DN[0]}" "$DB")]）⇒ 本相不对 Mod 释放下结论"
fi
assert_eq "合并后被删数据不得复活（d1）" "$(crm_rows_t "$DB.d1" s1)" "0"
assert_eq "合并后被删数据不得复活（d2）" "$(crm_rows_t "$DB.d2" s1)" "0"
assert_eq "合并后 d3 行数" "$(crm_wait_rows_t "$DB.d3" s1 "$ROWS" 60)" "$ROWS"
cmp_assert_same "合并前后 d3 指纹" "$FPD3_0" "$(cmp_fingerprint tree "select s1 from $DB.d3 order by time;")"
for h in "${DN[@]}"; do
  r=$(sq_node "$h" "select s1 from $DB.d3 order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9')
  [ "${r:-0}" = "$ROWS" ] && pass "$h 上 d3 行数=$r（三副本一致）" || fail "$h 上 d3 行数=$r（期望 $ROWS）"
done
PT=$(cmp_tmp_leftover "$DB")
[ "${PT:-0}" -eq 0 ] && pass "无残留临时文件（*.compaction.log/*.tmp/*.merge）" || warn "存在 $PT 个残留临时文件（记录）"

log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.d3 order by time;" tree
cmp_case_finish "" tree ""
