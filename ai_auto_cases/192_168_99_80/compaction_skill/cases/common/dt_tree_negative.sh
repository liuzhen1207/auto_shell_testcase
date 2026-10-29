#!/bin/bash
# ============================================================================
# DT-02 修改数据类型（树模型）负向 + 链式 + 改后写入
#
# 需求点（手册 2.3）：
#   ① 不兼容的类型转换必须被拒绝（原始类型只能改成兼容表里列出的类型）；
#   ② 路径不存在要明确报错（实测 508）；
#   ③ 类型变更后可继续按新类型写入；
#   ④ 变更失败时既有类型与数据保持不变（不得"半改"）。
# 用法： bash dt_tree_negative.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_tree_negative_${DATA_CONSENSUS}"

DB=root.dtneg
BASE=$(( ($(date +%s) - 3600) * 1000 ))

log "--- 集群准备：三类合并先关 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

dt02_mk(){ sq "create timeseries $DB.$1.s1 with datatype=$2, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null; }
dt02_w(){ sq "insert into $DB.$1(time,s1) values ($(( BASE + 100 )),$2),($(( BASE + 110 )),$3);" >/dev/null; }
dt02_setup(){ dt02_mk "$1" "$2"; case "$2" in
    INT32|INT64|TIMESTAMP) dt02_w "$1" 42 43 ;;
    FLOAT|DOUBLE)          dt02_w "$1" 1.5 2.5 ;;
    BOOLEAN)               dt02_w "$1" true false ;;
    TEXT|STRING|BLOB)      dt02_w "$1" "'abc'" "'def'" ;;
    DATE)                  dt02_w "$1" "'2026-01-02'" "'2026-01-03'" ;;
  esac; sq "flush;" >/dev/null; sleep 3; }

log "--- 1) 不兼容转换必须被拒绝且不改动类型/数据 ---"
i=0
for pair in "DOUBLE:FLOAT" "TEXT:INT32" "BOOLEAN:INT32" "TIMESTAMP:FLOAT" "STRING:INT32" "BLOB:INT64"; do
  src=${pair%%:*}; to=${pair#*:}; i=$(( i + 1 )); dev="n$i"
  dt02_setup "$dev" "$src"
  p="$DB.$dev.s1"
  ty0=$(cmp_series_type "$p"); fp0=$(cmp_fp_series "$p"); rows0=$(cmp_rows_series "$p")
  resp=$(cmp_alter_ts "$p" "$to")
  ty1=$(cmp_series_type "$p"); fp1=$(cmp_fp_series "$p"); rows1=$(cmp_rows_series "$p")
  if printf '%s' "$resp" | grep -qiE 'successfully'; then
    fail "  [$src → $to] 不兼容却被接受（响应：$(printf '%s' "$resp" | cut -c1-120)）"
  else
    pass "  [$src → $to] 被正确拒绝（$(printf '%s' "$resp" | grep -oE '[0-9]{3}: .*' | cut -c1-90)）"
  fi
  [ "$ty0" = "$ty1" ] && pass "  [$src → $to] 失败后类型未变（$ty0）" || fail "  [$src → $to] 失败后类型被改成 $ty1"
  [ "$fp0" = "$fp1" ] && [ "$rows0" = "$rows1" ] && pass "  [$src → $to] 失败后数据未变（$rows0 行）" \
    || fail "  [$src → $to] 失败后数据被改动（$rows0 → $rows1 行）"
done

log "--- 2) 路径不存在 / 库不存在 → 明确报错 ---"
r=$(cmp_alter_ts "$DB.no_such_dev.s1" DOUBLE)
printf '%s' "$r" | grep -qE '508|does not exist' && pass "  不存在的序列：$(printf '%s' "$r" | grep -oE '508: .*' | cut -c1-100)" \
  || fail "  不存在的序列未给出 508：$(printf '%s' "$r" | cut -c1-140)"
r=$(cmp_alter_ts "root.no_such_db.d1.s1" DOUBLE)
printf '%s' "$r" | grep -qE '508|does not exist' && pass "  不存在的库：$(printf '%s' "$r" | grep -oE '508: .*' | cut -c1-100)" \
  || warn "  不存在的库响应：$(printf '%s' "$r" | cut -c1-140)"

log "--- 3) 链式转换（每一步都要成功且类型随之变化）---"
dt02_setup chain INT32
p="$DB.chain.s1"; cur=INT32
for to in INT64 DOUBLE STRING TEXT; do
  resp=$(cmp_alter_ts "$p" "$to"); ty=$(cmp_series_type "$p")
  if printf '%s' "$resp" | grep -qi successfully && [ "$ty" = "$to" ]; then
    pass "  链式 $cur → $to 成功（当前类型=$ty）"
  else
    fail "  链式 $cur → $to 失败：ty=$ty resp=$(printf '%s' "$resp" | cut -c1-120)"
  fi
  cur=$to
done
log "    链式结束后数据=$(cmp_vals_series "$p" 4)"

log "--- 4) 改类型后按新类型写入 ---"
dt02_setup wr INT32
p="$DB.wr.s1"
cmp_alter_ts "$p" DOUBLE >/dev/null
n=$(sq "insert into $DB.wr(time,s1) values ($(( BASE + 200 )),9.5);" 2>&1 | grep -c successfully)
[ "${n:-0}" -ge 1 ] && pass "  改成 DOUBLE 后写入 9.5 成功" || fail "  改成 DOUBLE 后写入浮点值失败"
vals=$(cmp_vals_series "$p" 4)
printf '%s' "$vals" | grep -q '9.5' && pass "  新写入的值可读（$vals）" || warn "  新写入值读取异常（$vals）"
for h in "${DN[@]}"; do
  v=$(sq_node "$h" "select s1 from $DB.wr order by time;" 2>/dev/null | data_rows | wc -l | tr -dc '0-9')
  [ "${v:-0}" -ge 3 ] && pass "  经 $h 查询可见 3 行" || fail "  经 $h 只看到 ${v:-0} 行（期望 3）"
done

log "--- 收尾三件套（本用例故意触发过负向改写，这些预期错误列入 benign）---"
export CMP_LOG_BENIGN_EXTRA='not compatible with the existing one|Alter timeseries .* in schema regions failed|Status code: (507|508|701)|Path \[.*\] does not exist|does not exist'
post_checks "select s1 from $DB.wr order by time;" tree
cmp_case_finish "" tree ""
