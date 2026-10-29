#!/bin/bash
# ============================================================================
# CR-02 精度检查的兼容性与"时间分区膨胀"对照（tree 模型）
#   覆盖需求点：R-05 / R-06 / R-08（docs/REQ_MATRIX.md §1、§3 CR-02）
#
#   需求逐字要点：
#     R-05「时间戳精度检查不会显著影响写入性能。」（**只有定性表述 ⇒ 本用例只做弱判据：仅 WARN**）
#     R-06「默认开启精度检查会使得之前的一些写入操作变为非法。如果确有必要执行这些操作，
#           可以在升级后关闭该配置项。」⇒ A/B 对照：开启态同一批 SQL 全被拒、关闭态全部放行
#     R-08「观察 data 目录发现创建了 10 个时间分区。时间分区的间隔 7 天被缩小了 100_000 倍。」
#
#   场景（源自 R-02/R-03 的 ns 量级语料）：
#     精度 ms + 检查开启时，19 位 ns 时间戳（1693987852987000000 + k*1e9, k=0..9）全部非法；
#     关掉检查后这些值被当作 **ms** 落库 ⇒ 相邻相差 1e9 ms ≈ 11.6 天 ⇒ 落在互不相同的
#     "7 天时间分区"里 ⇒ data 目录出现 10 个时间分区（正是 R-08 记录的现象）。
#
#   源码依据（D:\IDEA\timechodb_src\v20121\timechodb，RC7=7c61428 为其祖先）：
#     · 门禁阈值/ns 短路：node-commons/.../TimestampPrecisionUtils.java:66-90（ms: `>10^13`）
#     · 开关每次调用现读 ⇒ 可热改：同上 :67-71；模板 effectiveMode: hot_reload（template:1562）
#     · 时间分区目录由 TsFileResource 注册时派生：datanode/.../DataRegion.java:4935（:5027 用到的分区 id）
#       ⇒ 只有**落盘**（`Async close`）之后 data 目录才会出现该分区目录（所以必须等 close 事件）
#     · PARTITION_INTERVAL（7 天）默认值来自 dn_data_dirs/时间分区配置；本用例只数目录、不硬编码间隔
#
#   判据（双信号 + 数据面 + 场景有效性硬断言）：
#     ① A 相（开启）：客户端逐字报错 **10 条**（每条都逐字核对四个片段）；数据面 0 行；时间分区数不变
#     ② B 相（关闭）：热改生效值 false（逐节点）→ 同一 10 条全部成功；数据面 10 行且载荷 1..10 逐条都在
#     ③ B 相：该库**自己的** region 目录下时间分区目录数（`<db>/<regionId>/<timePartition>`）显著增多
#        期望 +10；本用例硬断言 ≥ PART_MIN(默认 8)，不成立 ⇒ 判"**场景未成立**"（旧版行为/分区策略变更），
#        **不判产品缺陷**（REQ_MATRIX §3 CR-02 场景有效性③）
#     ④ R-05 弱判据：同一 2 万点写入在开关两态下计时对照，**仅当关闭态比开启态快 >30% 时 WARN**
#
#   注意（与 CR-01 相同的两处"文档↔源码"差异）：
#     · 错误码：矩阵写 SemanticException(≈507)，源码 TSStatusCode:131 是 SEMANTIC_ERROR(**701**)
#       ⇒ 判据接受 {1100,507,701} 并打印实测值（**待实测确认**）
#     · 边界：源码 `time > 10^13` ⇒ 恰好 10^13 放行（本用例只用远超阈值的语料，不涉及该边界）
#
#   无需重启（`timestamp_precision` 固定 ms，只热改开关）；时长约 12~18 分钟。
#   用法：bash cases/common/cr_ts_partition_balance.sh [--consensus IoTConsensus|IoTConsensusV2]
#
# ★ harness 修复记录（RC8 首轮实跑暴露，用例侧）：R-05 相的两条"新增写入点数"断言用了
#   `sqt/sq … | table_rows | wc -l` 数行。**CLI 单条结果超过一批（实测 1000 行/批）会重复打印表头**，
#   而 lib 的 `table_rows` 只丢第一行 ⇒ 5000 行被数成 **5004/5005**（多出的就是重复表头）。
#   现改为按"表头原文"整行剔除后再计数（`cr02_body_cnt`）；期望值 5000 **不变**（不是把期望改成实际）。
#   同一机制也影响 CR-06/CR-10 的表模型行数断言（已各自修）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_ts_partition_balance_${DATA_CONSENSUS}"

# ---------------------------------------------------------------- 变量（规模/语料放顶部）
DB=root.cr02                     # 主库（A/B 对照 + 分区计数）
DBP=root.cr02p                   # 性能对照库（R-05 弱判据；与主库隔离，避免污染分区计数）
DEV=d1
NS_BASE=1693987852987000000      # ns 量级基准（R-02/R-03 语料量级）
NS_STEP=1000000000               # 相邻差 1e9（ms 口径下 ≈ 11.6 天 ⇒ 每个都落进不同时间分区）
N_TS=10                          # R-08 原文现象 = 10 个时间分区
PART_MIN="${CR02_PART_MIN:-8}"    # 分区膨胀下限（<该值判"场景未成立"）
PERF_DEVS="${CR02_PERF_DEVS:-4}"
PERF_ROWS="${CR02_PERF_ROWS:-5000}"   # 点数 = PERF_DEVS × PERF_ROWS
PERF_BS="${CR02_PERF_BS:-500}"
BASE_CONF="$CMP_EXTRA_WRITE,timestamp_precision_check_enabled=true"
EVID="$ART/${CASE}.evidence.txt"
: >"$EVID"
REJ_N=0
ACC_N=0

# ---------------------------------------------------------------- 本地 helper
ev(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$EVID"; }
cr02_oneline(){ printf '%s' "$1" | tr '\n\r' '  ' | tr -s ' ' | cut -c1-400; }
cr02_code(){ printf '%s\n' "$1" | grep -oE 'IoTDBSQLException: [0-9]+' | head -1 | grep -oE '[0-9]+$'; }
cr02_sql(){ sq "$1"; }
cr02_ns_ts(){ echo $(( NS_BASE + $1 * NS_STEP )); }
# 原始查询数行（树方言具体设备路径上的聚合会退化，必须用原始查询数行）
#   ⚠️ **不能用 `table_rows | wc -l`**：CLI 单条查询结果超过一批（实测 1000 行/批）会
#   **重复打印表头**，而 lib 的 table_rows 只丢第一行 ⇒ 多批时行数虚高
#   （RC8 实测：5000 行被数成 **5004** = 5000 + 4 个重复表头）。这里按"表头原文"整行剔除后再数。
cr02_body_cnt(){ printf '%s\n' "$1" | grep -E '^\|' | grep -vE '^\|[-+ ]+\|$' \
  | awk -F'|' 'NR==1{h=$2; next} {if ($2==h) next; c++} END{print c+0}'; }
cr02_rows(){ cr02_raw_rows "$DB" "$DEV"; }
cr02_raw_rows(){ cr02_body_cnt "$(sq "select s1 from $1.$2 order by time;" 2>&1)"; }
cr02_vals(){ printf '%s\n' "$(sq "select s1 from $DB.$DEV order by time;" 2>&1)" | grep -E '^\|' \
  | grep -vE '^\|[-+ ]+\|$' | awk -F'|' 'NR==1{h=$2; next} {if ($2==h) next; v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v} END{print ""}'; }
cr02_haskey(){ printf '%s' "$2" | tr '|' '\n' | grep -qxF -- "$1"; }
cr02_wait_rows(){ local want=$1 win=$2 got=0
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(cr02_rows)
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 3
  done
  echo "${got:-0}"; return 1
}
cr02_msgcnt(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'The timestamp is unexpectedly large' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "$s"
}
# 该库**自己**的 region 目录下的时间分区目录数（路径形态 .../data/{sequence,unsequence}/<db>/<regionId>/<timePartition>）
#   统计"恰好位于 <db> 之后两层"的目录；**不要**用全局目录数或时间分区以外的层级
cr02_parts(){ local h=$1 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -type d -path '*/$DB/*' -printf '%p\n' 2>/dev/null | awk -F/ -v db='$DB' '{for(i=1;i<=NF;i++){if(\$i==db){if(NF==i+2)c++;break}}} END{print c+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"
}
cr02_parts_all(){ local h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}:$(cr02_parts "$h") "; done
  printf '%s' "$out"
}
cr02_parts_min(){ local h v m=""
  for h in "${DN[@]}"; do
    v=$(cr02_parts "$h")
    if [ -z "$m" ] || [ "${v:-0}" -lt "$m" ]; then m="${v:-0}"; fi
  done
  echo "${m:-0}"
}
# 等各副本的时间分区数（取最小值，即最落后的副本）涨到 target；稳定但未达标也提前结束
#   （分区目录只有 TsFile 真正 Async close 之后才出现，写入后需要给它一点时间）
cr02_wait_parts(){ local target=$1 win=$2 cur=0 prev=-1
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    cur=$(cr02_parts_min)
    [ "$cur" -ge "$target" ] && break
    if [ "$cur" = "$prev" ] && [ "$cur" -gt 0 ]; then break; fi
    prev=$cur
    sleep 6
  done
  echo "$cur"
}
# 等三副本时间分区数一致（去掉副本前置的 "77:"）；返回去重取值个数（1 = 一致）
cr02_wait_parts_uni(){ local win=$1 n
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    n=$(cr02_parts_all | tr ' ' '\n' | sed -n 's/^[0-9]*://p' | sort -u | wc -l | tr -dc '0-9')
    [ "${n:-0}" = "1" ] && break
    sleep 6
  done
  cr02_parts_all | tr ' ' '\n' | sed -n 's/^[0-9]*://p' | sort -u | wc -l | tr -dc '0-9'
}
cr02_eff_all(){ local k=$1 h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}=$(cmp_eff "$h" "$k") "; done
  printf '%s' "$out"
}
cr02_wait_eff(){ local k=$1 want=$2 win=$3 h v ok
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    ok=1
    for h in "${DN[@]}"; do
      v=$(cmp_eff "$h" "$k")
      [ "$v" = "$want" ] || ok=0
    done
    [ "$ok" = 1 ] && { printf '%s' "$(cr02_eff_all "$k")"; return 0; }
    sleep 3
  done
  printf '%s' "$(cr02_eff_all "$k")"; return 1
}
cr02_reject(){ local label=$1 out=$2 ts=$3 prec=${4:-ms} code joined
  REJ_N=$(( REJ_N + 1 ))
  ev "$label | $(cr02_oneline "$out")"
  code=$(cr02_code "$out")
  if [ -z "$code" ]; then
    fail "$label：期望被拒，实际成功（响应：$(cr02_oneline "$out")）"
  else
    case " 1100 507 701 " in
      *" $code "*) pass "$label：如期被拒 code=$code";;
      *) fail "$label：被拒但 code=$code ∉ {1100,507,701}（文档 1100 / 矩阵 507 / 源码 SEMANTIC_ERROR 701 ⇒ 待实测确认）";;
    esac
  fi
  joined=$(printf '%s' "$out" | tr '\n\r' '  ')
  if printf '%s' "$joined" | grep -qF 'The timestamp is unexpectedly large, you may forget to set the timestamp precision'; then
    pass "$label：文案①逐字匹配"
  else
    fail "$label：缺文案①（逐字：The timestamp is unexpectedly large, you may forget to set the timestamp precision）"
  fi
  if printf '%s' "$joined" | grep -qF "Current system timestamp precision is $prec"; then
    pass "$label：文案②含当前精度 $prec"
  else
    fail "$label：缺文案②（期望含 Current system timestamp precision is $prec）"
  fi
  if printf '%s' "$joined" | grep -qF "whether the timestamp $ts is correct"; then
    pass "$label：文案③回显时间戳 $ts"
  else
    fail "$label：缺文案③（期望含 whether the timestamp $ts is correct）"
  fi
}
cr02_accept(){ local label=$1 out=$2 code
  ACC_N=$(( ACC_N + 1 ))
  ev "$label | $(cr02_oneline "$out")"
  code=$(cr02_code "$out")
  if [ -z "$code" ]; then
    pass "$label：如期写入成功"
  else
    fail "$label：期望成功，实际报错 code=$code（$(cr02_oneline "$out")）"
  fi
}

# ============================================================================
# 集群准备（ms + 检查开启；写入期三类合并全关，避免分区/文件被合并改写）
# ============================================================================
log "--- 集群准备（ms 相 + 检查开启；三类合并全关；$BASE_CONF）---"
EXTRA_CONF="$BASE_CONF" cmp_cluster_prepare
cmp_compaction_off
for h in "${DN[@]}"; do
  got=$(cmp_eff "$h" timestamp_precision)
  [ -z "$got" ] && got=$(sshx "$h" "grep -E '^timestamp_precision=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
  assert_eq "  $h timestamp_precision" "${got:-}" "ms"
done
assert_eq "  开关生效值（${DN[0]}）" "$(cmp_eff "${DN[0]}" timestamp_precision_check_enabled)" "true"

log "--- 建库/建序列：$DB ---"
cr02_sql "create database $DB;" >/dev/null
cr02_sql "create timeseries $DB.$DEV.s1 with datatype=INT64;" >/dev/null
assert_eq "  场景有效：时序已建" "$(cr02_sql "show timeseries $DB.$DEV.s1;" | table_rows | wc -l | tr -dc '0-9')" "1"

# ============================================================================
# 相位 A：开启检查 ⇒ 10 条 ns 量级时间戳全部被拒（0 行、0 分区）
# ============================================================================
log "--- 相位 A：检查开启 ⇒ $N_TS 条 ns 量级时间戳全部被拒（R-06 的『旧写入变非法』）---"
REJ_N=0
LOG0=$(cr02_msgcnt)
P0=$(cr02_parts_min)
log "  A 相前：时间分区数（各副本最小值）=$P0；逐副本 $(cr02_parts_all)"
k=0
while [ "$k" -lt "$N_TS" ]; do
  ts=$(cr02_ns_ts "$k")
  r=$(cr02_sql "insert into $DB.$DEV(time,s1) values($ts,$(( k + 1 )));")
  cr02_reject "A$(( k + 1 )) ns 量级时间戳 $ts" "$r" "$ts" ms
  k=$(( k + 1 ))
done
cr02_sql "flush;" >/dev/null
assert_eq "A 相：客户端逐字报错条数" "$REJ_N" "$N_TS"
got=$(cr02_wait_rows 0 30)
assert_eq "A 相数据面：行数（被拒的不落行）" "$got" "0"
P1=$(cr02_parts_min)
assert_eq "A 相：时间分区数不变（被拒不产生分区）" "$P1" "$P0"
LOG1=$(cr02_msgcnt)
A_D=$(( LOG1 - LOG0 ))
if [ "$A_D" -ge "$N_TS" ]; then
  pass "A 相双信号①（辅）：DN 日志精度报错行数 +$A_D（≥$N_TS）"
else
  warn "A 相双信号①（辅）：DN 日志 'The timestamp is unexpectedly large' 行数 +$A_D（期望 ≥$N_TS）——错误多在解析层返回、未落 DN all 日志（REQ_MATRIX §3 CR-01 场景有效性③ 允许记 WARN）；客户端侧已逐条拿到逐字文案（见 $EVID）"
fi

# ============================================================================
# 相位 B：热关检查 ⇒ 同一 10 条全部写入，时间分区显著增多（R-08）
# ============================================================================
log "--- 相位 B：热关检查（R-06）⇒ 同一 $N_TS 条全部写入 ⇒ 数时间分区（R-08）---"
REJ_N=0; ACC_N=0
hot=$(cmp_is_hot_key timestamp_precision_check_enabled false | tail -1)
assert_eq "  开关是否热加载" "$hot" "yes"
if cr02_wait_eff timestamp_precision_check_enabled false 90 >/dev/null; then
  pass "场景有效：热关后三节点生效值一致（$(cr02_eff_all timestamp_precision_check_enabled)）"
else
  fail "场景未成立：热关后三节点生效值不一致（$(cr02_eff_all timestamp_precision_check_enabled)）"
fi
k=0
while [ "$k" -lt "$N_TS" ]; do
  ts=$(cr02_ns_ts "$k")
  r=$(cr02_sql "insert into $DB.$DEV(time,s1) values($ts,$(( k + 1 )));")
  cr02_accept "B$(( k + 1 )) 关闭检查后同一时间戳 $ts" "$r"
  k=$(( k + 1 ))
done
assert_eq "B 相：客户端成功条数" "$ACC_N" "$N_TS"
assert_eq "B 相：拒绝条数（关闭态不应有精度报错）" "$REJ_N" "0"
cr02_sql "flush;" >/dev/null
ensure_closed "$DB" 3 25 || warn "有 DN 的 TsFile 未 Async close（未落盘的分区目录不会被创建 ⇒ 分区计数可能偏小）"

got=$(cr02_wait_rows "$N_TS" 120)
assert_eq "B 相数据面：行数" "$got" "$N_TS"
vals=$(cr02_vals)
ok=1
k=1
while [ "$k" -le "$N_TS" ]; do
  cr02_haskey "$k" "$vals" || ok=0
  k=$(( k + 1 ))
done
if [ "$ok" = 1 ]; then
  pass "B 相数据面：载荷 1..$N_TS 逐条都在（$vals）"
else
  fail "B 相数据面：载荷缺失（实际 $vals）"
fi

P2=$(cr02_wait_parts "$N_TS" 90)
GROW=$(( P2 - P1 ))
log "  时间分区数（各副本最小值）：A 相后=$P1 → B 相后=$P2（+$GROW，期望 +$N_TS）；逐副本 $(cr02_parts_all)"
nuniq=$(cr02_wait_parts_uni 60)
assert_eq "B 相：三副本时间分区数一致（去重取值个数）" "$nuniq" "1"
if [ "$GROW" -ge "$PART_MIN" ]; then
  pass "R-08 时间分区膨胀：该库新增 $GROW 个时间分区（≥$PART_MIN；需求原文现象为 $N_TS 个）"
else
  fail "场景未成立：关闭相时间分区只新增 $GROW 个（<$PART_MIN，逐副本 $(cr02_parts_all)）——先查 FLUSH 是否真的 Async close 落盘、时间分区间隔/dn_data_dirs 配置；仍不成立按 REQ_MATRIX §3 CR-02 场景有效性③ 记'场景未成立'，**不判产品缺陷**"
fi
if [ "$GROW" -ne "$N_TS" ]; then
  warn "R-08 观察：新增时间分区 $GROW 个（需求原文记录为 $N_TS 个）⇒ 记录实际值供跨版本比较"
fi

# ============================================================================
# 相位 C：R-05 弱判据（同一 2 万点写入在开关两态的耗时对照；仅 WARN）
# ============================================================================
log "--- 相位 C：R-05 弱判据（$(( PERF_DEVS * PERF_ROWS )) 点在开关两态下的写入耗时对照）---"
cr02_sql "create database $DBP;" >/dev/null
d=1
while [ "$d" -le "$PERF_DEVS" ]; do
  cr02_sql "create timeseries $DBP.d$d.s1 with datatype=INT64;" >/dev/null
  d=$(( d + 1 ))
done
PBASE=$(( ($(date +%s) - 3600) * 1000 ))
# 两态用互不重叠的时间戳区间（都在已落盘水位之后 ⇒ 都落 sequence，写入量一致）
# 开启态：必须先**显式**把开关置回 true 再计时（B 相结束时是 false —— 曾漏写这一步）
cmp_set_hot timestamp_precision_check_enabled true >/dev/null
if cr02_wait_eff timestamp_precision_check_enabled true 90 >/dev/null; then
  pass "  R-05 相：开启态场景有效（三节点生效值均为 true）"
else
  fail "  R-05 相：场景未成立——置回 true 后三节点生效值不一致（$(cr02_eff_all timestamp_precision_check_enabled)）"
fi
c_on0=$(cr02_raw_rows "$DBP" d1)
t0=$(now_ms)
cmp_bulk_tree_session "$DBP" "$PERF_DEVS" "$PERF_ROWS" 1 "$PBASE" "$PERF_BS" >/dev/null
t1=$(now_ms)
ON_MS=$(( t1 - t0 ))
got=$(cr02_raw_rows "$DBP" d1)
assert_eq "  R-05 相：开启态新增写入点数（d1，相对基线 $c_on0）" "$(( ${got:-0} - ${c_on0:-0} ))" "$PERF_ROWS"
cmp_set_hot timestamp_precision_check_enabled false >/dev/null
cr02_wait_eff timestamp_precision_check_enabled false 90 >/dev/null || warn "  R-05 相：开关热关未在三节点生效（$(cr02_eff_all timestamp_precision_check_enabled)）"
c_off0=$(cr02_raw_rows "$DBP" d1)
t2=$(now_ms)
cmp_bulk_tree_session "$DBP" "$PERF_DEVS" "$PERF_ROWS" 2 "$(( PBASE + 3600000 ))" "$PERF_BS" >/dev/null
t3=$(now_ms)
OFF_MS=$(( t3 - t2 ))
got=$(cr02_raw_rows "$DBP" d1)
assert_eq "  R-05 相：关闭态新增写入点数（d1，相对基线 $c_off0）" "$(( ${got:-0} - ${c_off0:-0} ))" "$PERF_ROWS"
cmp_set_hot timestamp_precision_check_enabled true >/dev/null
cr02_wait_eff timestamp_precision_check_enabled true 90 >/dev/null || warn "  收尾前开关未置回 true（$(cr02_eff_all timestamp_precision_check_enabled)）"
RATIO=$(awk -v a="$OFF_MS" -v b="$ON_MS" 'BEGIN{ if (b > 0) printf "%.2f", a / b; else printf "1.00" }')
log "  R-05 记录：开启态 ${ON_MS}ms / 关闭态 ${OFF_MS}ms ⇒ 关闭态/开启态 = $RATIO（点数 $(( PERF_DEVS * PERF_ROWS ))，同机同负载）"
if awk -v r="$RATIO" 'BEGIN{ exit !(r + 0 < 0.7) }'; then
  warn "R-05 弱判据：关闭态比开启态快 >30%（比值 $RATIO，开启态 ${ON_MS}ms / 关闭态 ${OFF_MS}ms）⇒ 值得研发关注（原文只说'不会显著影响'，无阈值依据，**不判 FAIL**）"
else
  pass "R-05 弱判据：两态耗时同量级（比值 $RATIO ≤ 0.7 的加速门槛未触发；开启态 ${ON_MS}ms / 关闭态 ${OFF_MS}ms）"
fi

# ============================================================================
# 收尾三件套
# ============================================================================
log "--- 收尾三件套（基准 SQL：$DB.$DEV 原始查询）---"
export CMP_LOG_BENIGN_EXTRA='The timestamp is unexpectedly large|timestamp_precision_check_enabled|unexpectedly large'
post_checks "select s1 from $DB.$DEV order by time;" tree
cmp_case_finish "" tree ""
