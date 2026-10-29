#!/bin/bash
# ============================================================================
# CO-07 冒烟：多种数据类型 × 多种编码 的数据在合并前后完全一致
#   做法：每个设备用一种 (datatype, encoding) 组合建一个序列 → 3 批写入（含负数/极值/
#         NaN、Infinity、特殊字符文本）→ 合并 → 断言 `select * from db.**` 的完整结果
#         合并前后逐字节一致（归一化后比较），并逐个序列再比一次。
#   特殊字面量（极值/NaN/Infinity/含引号文本）不同构建的支持度可能不同：
#         先做一次"支持性探测"逐条记录（接受/拒绝），被拒绝的字面量在正式写入时**自动回退**
#         成普通值，只记 WARN —— 本用例验证的是"合并前后数据不变"，不是字面量支持度。
#   判据：成功建成的序列 ≥ 6 → 合并完成且文件数下降 → 全库指纹与逐序列指纹都不变 →
#         表头（类型）不变 → 无卡死线程 → 收尾三件套。
# 用法： bash co_data_types_encoding.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_data_types_encoding_${DATA_CONSENSUS}"

DB=root.cotypes
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-120}

# (datatype, encoding) 组合；建不成的只记 WARN，不判 FAIL（不同构建支持的编码集合不同）
COMBOS=(
  "int32:plain" "int32:rle" "int32:ts_2diff" "int32:zigzag"
  "int64:plain" "int64:rle" "int64:ts_2diff" "int64:zigzag"
  "float:plain" "float:rle" "float:ts_2diff" "float:gorilla"
  "double:plain" "double:rle" "double:ts_2diff" "double:gorilla"
  "boolean:plain" "boolean:rle"
  "text:plain" "text:dictionary"
  "string:plain" "string:dictionary"
  "timestamp:plain" "timestamp:ts_2diff"
)
# 依据类型给出该行(第 k 行)的 SQL 字面量（k=1..5 是特殊值，k≥6 是普通值）
co_literal(){ local t=$1 k=$2
  case "$t" in
    int32)  if [ "$k" = "1" ]; then echo 2147483647; elif [ "$k" = "2" ]; then echo -2147483648; else echo $(( k * 7 - 1000 )); fi ;;
    int64)  if [ "$k" = "1" ]; then echo 9223372036854775807; elif [ "$k" = "2" ]; then echo -9223372036854775808; else echo $(( k * 1000003 - 500000 )); fi ;;
    float|double)
            if [ "$k" = "3" ]; then echo "NaN"; elif [ "$k" = "4" ]; then echo "'Infinity'";
            elif [ "$k" = "5" ]; then echo "'-Infinity'"; else echo "$k.25" ; fi ;;
    boolean) [ $(( k % 2 )) -eq 0 ] && echo true || echo false ;;
    timestamp) echo $(( 1700000000000 + k * 10 )) ;;
    *)      if [ $(( k % 50 )) -eq 0 ]; then echo "'sp,ec\"i@l中 文$k'"; else echo "'str_$k'"; fi ;;
  esac; }
# 普通值（回退用，不会失败）
co_literal_safe(){ local t=$1 k=$2
  case "$t" in
    int32)  echo $(( k * 7 - 1000 )) ;;
    int64)  echo $(( k * 1000003 - 500000 )) ;;
    float|double) echo "$k.5" ;;
    boolean) [ $(( k % 2 )) -eq 0 ] && echo true || echo false ;;
    timestamp) echo $(( 1700000000000 + k * 10 )) ;;
    *)      echo "'str_$k'" ;;
  esac; }
# 每种类型要探测的特殊字面量（每行一个，含空格的文本字面量靠 read 保留）
co_specials(){ local t=$1
  case "$t" in
    int32)  printf '%s\n' 2147483647 -2147483648 ;;
    int64)  printf '%s\n' 9223372036854775807 -9223372036854775808 ;;
    float|double) printf '%s\n' "NaN" "'Infinity'" "'-Infinity'" ;;
    boolean) printf '%s\n' true false ;;
    text|string) printf '%s\n' "'sp,ec\"i@l中 文1'" "'a''b'" ;;
    timestamp) printf '%s\n' 1700000000000 ;;
    *) printf '%s\n' 1 ;;
  esac; }
# 被构建拒绝的字面量集合（前后带空格，便于整词匹配）
SPEC_REJECT=" "
spec_rej(){ case "$SPEC_REJECT" in *" $1 "*) return 0;; *) return 1;; esac; }
# 执行一条写语句；$1 必须是**设备路径**（不是序列路径）；返回 0 = 成功，1 = 报错
co_insert(){ local p=$1 ts=$2 lit=$3 out
  out=$(sq "insert into $p(time,s) values ($ts,$lit);")
  printf '%s' "$out" | grep -qiE 'error|Msg: org\.apache' && return 1
  return 0; }

log "--- 集群准备（合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- 建库 + 按 (类型,编码) 组合建序列 ---"
sq "create database $DB;" >/dev/null
SERIES=(); i=0
for combo in "${COMBOS[@]}"; do
  t=${combo%%:*}; e=${combo##*:}; i=$(( i + 1 )); dev="d$i"; path="$DB.$dev.s"
  out=$(sq "create timeseries $path with datatype=$t encoding=$e;")
  if printf '%s' "$out" | grep -q 'successfully'; then
    SERIES+=("$dev:$t:$e"); pass "建序列成功：$dev ($t/$e)"
  else
    warn "建序列失败（跳过）：$dev ($t/$e) → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
  fi
done
log "  成功建成 $((${#SERIES[@]})) / ${#COMBOS[@]} 个组合"
[ "${#SERIES[@]}" -ge 6 ] && pass "成功建成 ≥6 种类型/编码组合（$((${#SERIES[@]}))）" || fail "成功建成的组合过少（$((${#SERIES[@]}))），用例覆盖不足"

log "--- 特殊字面量支持性探测（每个类型 1 个 probe 设备，逐条写，被拒的只记录）---"
TYPES=$(for s in "${SERIES[@]}"; do printf '%s\n' "$s" | cut -d: -f2; done | sort -u)
for t in $TYPES; do
  pp="$DB.spec_$t"
  sq "create timeseries $pp.s with datatype=$t encoding=plain;" >/dev/null
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    if co_insert "$pp" 1700000000000 "$lit"; then
      log "    接受: $t ← $lit"
    else
      SPEC_REJECT="$SPEC_REJECT $lit "
      log "    拒绝: $t ← $lit"
    fi
  done < <(co_specials "$t")
done
if [ "$(printf '%s' "$SPEC_REJECT" | tr -d ' ')" = "" ]; then
  pass "所有特殊字面量都被本构建接受（极值/NaN/Infinity/特殊字符）"
else
  warn "被本构建拒绝的特殊字面量（正式写入已自动回退为普通值）：$(printf '%s' "$SPEC_REJECT" | tr -s ' ')"
fi

log "--- 写 3 批数据（每批 $ROWS 点/序列；k=1..5 用 accepted 的特殊值）---"
# 注意：insert 的 prefixPath 是**设备路径**（`insert into <device>(time, <measurement>)`），
# 写成序列路径（`insert into db.d1.s(time,s)`）会被当成"设备 db.d1.s + 测量 s"⇒
# `507 TSStatus(code:506, message:Path [db.d1.s] already exist)`（实测踩到，所有插入全失败）。
BASE=$(( ($(date +%s) - 3600) * 1000 ))
for b in 1 2 3; do
  for s in "${SERIES[@]}"; do
    dev=${s%%:*}; t=$(printf '%s' "$s" | cut -d: -f2); p="$DB.$dev.s"; devp="$DB.$dev"
    start=$(( BASE + (b-1) * 2000000 )); vals=""
    for ((k=1;k<=ROWS;k++)); do
      lit=$(co_literal "$t" "$k")
      spec_rej "$lit" && lit=$(co_literal_safe "$t" "$k")
      vals="$vals($(( start + k * 10 )),$lit),"
      if [ $(( k % 500 )) -eq 0 ]; then
        if ! sq "insert into $devp(time,s) values ${vals%,};" >/dev/null; then
          # 整批失败（可能是某个字面量没探测到）：回退成普通值重写一次，只记 WARN
          vals2=""
          for ((j=k-499;j<=k;j++)); do vals2="$vals2($(( start + j * 10 )),$(co_literal_safe "$t" "$j")),"; done
          sq "insert into $devp(time,s) values ${vals2%,};" >/dev/null \
            && warn "批 $b 序列 $dev 有字面量被拒，已用普通值回退重写" \
            || fail "写入失败 $devp 批$b"
        fi
        vals=""
      fi
    done
    if [ -n "$vals" ]; then
      if ! sq "insert into $devp(time,s) values ${vals%,};" >/dev/null; then
        n=$(( ROWS % 500 )); [ "$n" -eq 0 ] && n=500; vals2=""
        for ((j=ROWS-n+1;j<=ROWS;j++)); do vals2="$vals2($(( start + j * 10 )),$(co_literal_safe "$t" "$j")),"; done
        sq "insert into $devp(time,s) values ${vals2%,};" >/dev/null \
          && warn "批 $b 序列 $dev 有字面量被拒，已用普通值回退重写" \
          || fail "写入失败 $devp 批$b"
      fi
    fi
  done
  sq "flush;" >/dev/null
done
ensure_closed "$DB" 3 25 || warn "$DB 有 DN 的 TsFile 未落盘"

ts0=$(cmp_all_sum "$DB"); fin0=$(cmp_inner_finish "$DB")
log "  起点：TsFile=$ts0 finishes=$fin0"
[ "$ts0" -ge 2 ] && pass "起点 TsFile=$ts0（≥2）" || fail "场景无效：起点 TsFile=$ts0（<2）"

log "--- 合并前指纹 ---"
fp0=$(cmp_fingerprint tree "select * from $DB.**")
HDR0=$(sq "select * from $DB.**;" | grep -m1 '^|')
declare -A FP_BEFORE=()
for s in "${SERIES[@]}"; do dev=${s%%:*}; p="$DB.$dev.s"
  FP_BEFORE[$dev]=$(cmp_fingerprint tree "select s from $p order by time"); done
log "  全库表头：$(printf '%s' "$HDR0" | cut -c1-200)"

log "--- 等合并（窗口 ${WIN}s）---"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$WIN"); then pass "合并已推进：$RES"; else fail "合并未推进（$RES）"; fi

log "--- 合并后校验：数据类型/编码与数值都必须一致 ---"
cmp_assert_same "全库 select * 指纹" "$fp0" "$(cmp_fingerprint tree "select * from $DB.**")"
HDR1=$(sq "select * from $DB.**;" | grep -m1 '^|')
[ "$HDR0" = "$HDR1" ] && pass "结果表头（列=序列，含类型信息）不变" || fail "结果表头变化：$HDR0 → $HDR1"
for s in "${SERIES[@]}"; do dev=${s%%:*}
  cmp_assert_same "序列 $dev 全序列" "${FP_BEFORE[$dev]}" "$(cmp_fingerprint tree "select s from $DB.$dev.s order by time;")"
done

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套 ---"
post_checks "select s from $DB.d1.s order by time;" tree
cmp_case_finish "" tree ""
