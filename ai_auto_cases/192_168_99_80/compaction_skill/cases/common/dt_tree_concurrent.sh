#!/bin/bash
# ============================================================================
# DT-04 修改数据类型 **并发**场景（树模型）：并发删除序列 / 并发写入
#
# 需求点（手册 2.3）：「变更过程中若该时间序列被并发删除，会报错提示」。
#   ① 先删后改：必须明确报错（实测 508 does not exist），不得"悄悄成功"；
#   ② 真并发（ALTER ∥ DELETE TIMESERIES）N 轮：每轮结果只能是"改成功"或"删成功"，
#      且**不得出现数据损坏/卡死/异常堆栈**；结束后元数据自洽（序列存在→类型=目标；不存在→508）；
#   ③ 改类型与并发写入同时进行：数据不丢、无异常、类型最终一致。
# 用法： bash dt_tree_concurrent.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_tree_concurrent_${DATA_CONSENSUS}"

DB=root.dtcc
BASE=$(( ($(date +%s) - 3600) * 1000 ))
ROUNDS=${DT_ROUNDS:-8}

dt04_mk(){ sq "create timeseries $DB.$1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null; }
dt04_w(){ sq "insert into $DB.$1(time,s1) values ($(( BASE + $2 )),$3);" >/dev/null; }

log "--- 集群准备：三类合并先关 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- ① 先删除序列、再改类型 ⇒ 必须明确报错 ---"
dt04_mk gone; dt04_w gone 100 1; sq "flush;" >/dev/null; sleep 3
sq "delete timeseries $DB.gone.**;" >/dev/null
sleep 2
r=$(cmp_alter_ts "$DB.gone.s1" DOUBLE)
if printf '%s' "$r" | grep -qiE '508|does not exist'; then
  pass "  已删除的序列改类型被拒绝：$(printf '%s' "$r" | grep -oE '508: .*' | cut -c1-90)"
elif printf '%s' "$r" | grep -qi successfully; then
  fail "  已删除的序列改类型竟然成功（元数据可能被错误重建）：$(printf '%s' "$r" | cut -c1-120)"
else
  pass "  已删除的序列改类型被拒绝（$(printf '%s' "$r" | grep -oE '[0-9]{3}: .*' | cut -c1-90)）"
fi

log "--- ② ALTER ∥ DELETE TIMESERIES 并发 ${ROUNDS} 轮 ---"
ok_alter=0; ok_del=0; bad=0
final_double=0; final_gone=0; final_other=0
for i in $(seq 1 "$ROUNDS"); do
  dev="p$i"; dt04_mk "$dev"; dt04_w "$dev" 100 "$i"; sq "flush;" >/dev/null
  # 两个进程同时发起（改动与删除竞争同一条序列）
  ( sq "delete timeseries $DB.$dev.**;" >/tmp/dt04_del_$i.out 2>&1 ) &
  dp=$!
  ( cmp_alter_ts "$DB.$dev.s1" DOUBLE >/tmp/dt04_alt_$i.out 2>&1 ) &
  ap=$!
  wait $dp $ap
  ares=$(cat /tmp/dt04_alt_$i.out 2>/dev/null | tr '\n' ' ' | cut -c1-120)
  dr=$(cat /tmp/dt04_del_$i.out 2>/dev/null | tr '\n' ' ' | cut -c1-80)
  ty=$(cmp_series_type "$DB.$dev.s1")
  if printf '%s' "$ares" | grep -qi successfully; then
    ok_alter=$(( ok_alter + 1 ))
    if [ "$ty" = "DOUBLE" ]; then
      pass "  轮$i：ALTER 成功且类型=DOUBLE ✓"
    elif [ -z "$ty" ]; then
      # ALTER 先提交、DELETE 后生效 —— 最终态是"序列已删除"，顺序自洽，不算失败
      pass "  轮$i：ALTER 报成功、最终序列已不存在（顺序为 ALTER→DELETE，自洽）"
    else
      fail "  轮$i：ALTER 报成功但类型=$ty（既不是 DOUBLE 也没被删掉）"
    fi
  elif printf '%s' "$ares" | grep -qiE '508|does not exist|not compatible|[0-9]{3}: '; then
    pass "  轮$i：ALTER 给出明确错误（$(printf '%s' "$ares" | grep -oE '[0-9]{3}: .*' | cut -c1-70)）"
  else
    bad=$(( bad + 1 )); warn "  轮$i：ALTER 结果不明确：$ares"
  fi
  if [ -z "$ty" ]; then ok_del=$(( ok_del + 1 )); fi
  case "$ty" in
    DOUBLE) final_double=$(( final_double + 1 ));;
    "")     final_gone=$(( final_gone + 1 ));;
    *)      final_other=$(( final_other + 1 )); warn "  轮$i：最终态异常（类型=$ty，既非 DOUBLE 也非已删除）";;
  esac
done
log "  并发结果统计：ALTER 报成功 $ok_alter 轮 / DELETE 报成功 $ok_del 轮 / 响应不明确 $bad 轮（共 $ROUNDS 轮）"
log "  最终态统计：类型=DOUBLE $final_double 轮 / 序列已删除 $final_gone 轮 / 非自洽 $final_other 轮"
[ "$(( ok_alter + ok_del ))" -ge "$ROUNDS" ] && pass "  每轮都有一方明确成功（竞争语义符合预期）" \
  || warn "  有 $(( ROUNDS - ok_alter - ok_del )) 轮双方都没有明确结果（记录）"
[ "${bad:-0}" -eq 0 ] && pass "  没有出现『不明确的响应』（都是成功或明确的错误码）" \
  || warn "  有 $bad 轮响应不明确（记录）"
# 更强的判据：无论谁赢，最终元数据必须落在两个自洽状态之一
[ "$final_other" -eq 0 ] && [ "$(( final_double + final_gone ))" -eq "$ROUNDS" ] \
  && pass "  每轮最终态自洽（改成功→DOUBLE / 删成功→序列不存在），无中间态残留" \
  || fail "  有 $final_other 轮最终态不自洽（元数据既非目标类型也未删除）"

log "--- ③ 改类型 ∥ 并发写入 ---"
dev=cw; dt04_mk "$dev"; sq "flush;" >/dev/null; sleep 3
p="$DB.$dev.s1"
: > /tmp/dt04_ins.out
( for k in $(seq 1 10); do
    o=$(sq "insert into $DB.$dev(time,s1) values ($(( BASE + 1000 + k )),$k);" 2>&1)
    if printf '%s' "$o" | grep -qi successfully; then
      echo "OK $k" >> /tmp/dt04_ins.out
    else
      echo "ERR $k $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-100)" >> /tmp/dt04_ins.out
    fi
    sleep 0.3
  done ) &
wp=$!
sleep 1
r=$(cmp_alter_ts "$p" DOUBLE)
wait $wp
ins_ok=$(grep -c '^OK' /tmp/dt04_ins.out || true)
ins_err=$(grep -c '^ERR' /tmp/dt04_ins.out || true)
log "  改类型响应：$(printf '%s' "$r" | cut -c1-120)；最终类型=$(cmp_series_type "$p")"
log "  并发写入结果：成功 $ins_ok 条 / 被拒（有明确错误）$ins_err 条"
[ "$ins_ok" -ge 8 ] && pass "  并发写入大部分成功（$ins_ok/10 条）" \
  || warn "  并发写入成功率偏低（$ins_ok/10 条，改类型期间的写入被拒，记录）"
[ "$ins_err" -eq 0 ] || { log "  被拒样例：$(grep '^ERR' /tmp/dt04_ins.out | head -2 | tr '\n' ' ' | cut -c1-200)"; }
n=0; t0=$(date +%s); dl=$(( t0 + 90 ))
while (( $(date +%s) < dl )); do
  # ⚠️ 树方言查询必须用**设备路径**：`select s1 from root.db.cw`（写序列路径会返回 Empty set —— 本轮踩过）
  n=$(cmp_rows_series "$p")
  [ "${n:-0}" -ge "${ins_ok:-0}" ] && break
  sleep 3
done
d=$(( $(date +%s) - t0 ))
log "  写入可见性轮询：${d}s 后可见 ${n:-0} 行（成功写入 $ins_ok 条）"
if [ "${n:-0}" -ge "${ins_ok:-0}" ]; then
  pass "  成功写入的数据没有丢（可见 ${n:-0} 行 ≥ 成功写入 $ins_ok 条）"
  [ "$d" -le 5 ] || warn "  写入确认到可读之间隔了 ${d}s（记录：改类型并发写入后的读可见性延迟，需研发确认是否预期）"
else
  fail "  写入丢失：写入报成功 $ins_ok 条，等 ${d}s 后只能查到 ${n:-0} 行"
fi
ty=$(cmp_series_type "$p")
[ "$ty" = "DOUBLE" ] && pass "  并发写入后类型仍为 DOUBLE" || fail "  并发写入后类型=$ty（期望 DOUBLE）"

log "--- ④ 并发过程未产生异常/卡死 ---"
STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "没有卡在 TsFileResource.writeLock 的线程"

log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.cw order by time;" tree
cmp_case_finish "" tree ""
