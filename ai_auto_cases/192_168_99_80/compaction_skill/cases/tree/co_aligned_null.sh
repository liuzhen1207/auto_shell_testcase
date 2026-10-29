#!/bin/bash
# ============================================================================
# CO-08 冒烟：对齐序列（aligned）+ 空值（null）在合并前后完全一致
#   做法：建对齐设备（多序列）与非对齐设备（带空洞），不同序列在各时间点只写一部分
#         （制造 null）→ 多批 → 合并 → `select * from db.**` 与逐序列结果逐字节一致，
#         并校验 null 个数不变。
#   判据：合并完成且文件数下降 → 全库/逐序列指纹一致、null 计数一致 → 无卡死线程 → 收尾三件套。
#   两个实测坑（第一版踩到）：
#     ① bash 算术不支持浮点：`$((k*1.5))` 直接报 `syntax error: invalid arithmetic operator`，
#        整条插入被跳过 ⇒ 这一类序列一条数据都没写进去；
#     ② 对齐 + 空洞场景下**每个 flush 不一定落一个新 TsFile**：第一版 3 批只得到 1 个文件/DN，
#        合并候选不足 ⇒ "合并未推进"（场景无效，不是产品问题）。
#        现在每批后 `ensure_closed` 等落盘，文件数不足时自动补写批次（最多 6 批）。
# 用法： bash co_aligned_null.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_aligned_null_${DATA_CONSENSUS}"

DB=root.coalign
ROWS=${CO_ROWS:-300}
WIN=${CO_WIN_SEC:-120}

# 写一批数据：d1 对齐（s1 全写、s2 隔一个、s3 每 3 个）、d2 只写前半批（尾部空洞）
co08_batch(){ local b=$1 start=$2 k vals
  vals=""; for ((k=1;k<=ROWS;k++)); do vals="$vals($(( start + k*10 )),$((k+b))),"
    if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null; vals=""; fi; done
  [ -n "$vals" ] && sq "insert into $DB.d1(time,s1) values ${vals%,};" >/dev/null
  vals=""; for ((k=1;k<=ROWS;k+=2)); do vals="$vals($(( start + k*10 )),$(( k + b )).5),"
    if [ $(( (k+1)/2 % 500 )) -eq 0 ]; then sq "insert into $DB.d1(time,s2) values ${vals%,};" >/dev/null; vals=""; fi; done
  [ -n "$vals" ] && sq "insert into $DB.d1(time,s2) values ${vals%,};" >/dev/null
  vals=""; for ((k=1;k<=ROWS;k+=3)); do vals="$vals($(( start + k*10 )),'v$k'),"
    if [ $(( (k+2)/3 % 500 )) -eq 0 ]; then sq "insert into $DB.d1(time,s3) values ${vals%,};" >/dev/null; vals=""; fi; done
  [ -n "$vals" ] && sq "insert into $DB.d1(time,s3) values ${vals%,};" >/dev/null
  vals=""; for ((k=1;k<=ROWS/2;k++)); do vals="$vals($(( start + k*10 )),$k),"
    if [ $(( k % 500 )) -eq 0 ]; then sq "insert into $DB.d2(time,s1) values ${vals%,};" >/dev/null; vals=""; fi; done
  [ -n "$vals" ] && sq "insert into $DB.d2(time,s1) values ${vals%,};" >/dev/null
  sq "flush;" >/dev/null
  ensure_closed "$DB" 2 20 || warn "批 $b 未全部落盘"
}

log "--- 集群准备（合并参数：$CMP_EXTRA_CONF）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- 建库：对齐设备 d1(s1,s2,s3) + 非对齐设备 d2(s1) ---"
sq "create database $DB;" >/dev/null
out=$(sq "create aligned timeseries $DB.d1(s1 int64, s2 double, s3 text);")
printf '%s' "$out" | grep -q successfully && pass "建对齐序列成功" || fail "建对齐序列失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
out=$(sq "create timeseries $DB.d2.s1 with datatype=int64;")
printf '%s' "$out" | grep -q successfully && pass "建非对齐序列成功" || fail "建非对齐序列失败"

log "--- 写批次：不同序列在不同时间点写入 → 制造 null（每批 flush + 等落盘）---"
BASE=$(( ($(date +%s) - 3600) * 1000 ))
B=0; ts0=0
while [ "$B" -lt 6 ]; do
  B=$(( B + 1 ))
  co08_batch "$B" "$(( BASE + (B-1) * 2000000 ))"
  ts0=$(cmp_all_sum "$DB")
  log "  第 $B 批写完：TsFile=$ts0"
  [ "${ts0:-0}" -ge 2 ] && [ "$B" -ge 3 ] && break
done
log "  共写 $B 批，起点 TsFile=$ts0"
[ "${ts0:-0}" -ge 2 ] && pass "起点 TsFile=$ts0（≥2，具备合并条件）" || fail "场景无效：起点 TsFile=$ts0（<2，合并候选不足）"
fin0=$(cmp_inner_finish "$DB")

fp_all0=$(cmp_fingerprint tree "select * from $DB.**")
fp_s1_0=$(cmp_fingerprint tree "select s1 from $DB.d1 order by time;")
fp_s2_0=$(cmp_fingerprint tree "select s2 from $DB.d1 order by time;")
fp_s3_0=$(cmp_fingerprint tree "select s3 from $DB.d1 order by time;")
fp_d2_0=$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")
null_cnt(){ printf '%s\n' "$1" | grep -o 'null' | wc -l | tr -d ' '; }
N0=$(null_cnt "$fp_all0")
log "  合并前：null 出现次数=$N0（对齐序列未写入的点会补 null）"
[ "${N0:-0}" -gt 0 ] && pass "场景包含 null（$N0 处）" || warn "本轮未观测到 null（对齐序列可能被补全）"

log "--- 等合并（窗口 ${WIN}s）---"
cmp_compaction_on true true false
if RES=$(cmp_wait_merge "$DB" "$fin0" "$ts0" "$WIN"); then pass "合并已推进：$RES"; else fail "合并未推进（$RES）"; fi

fp_all1=$(cmp_fingerprint tree "select * from $DB.**")
cmp_assert_same "全库 select * 指纹" "$fp_all0" "$fp_all1"
cmp_assert_same "对齐序列 d1.s1" "$fp_s1_0" "$(cmp_fingerprint tree "select s1 from $DB.d1 order by time;")"
cmp_assert_same "对齐序列 d1.s2" "$fp_s2_0" "$(cmp_fingerprint tree "select s2 from $DB.d1 order by time;")"
cmp_assert_same "对齐序列 d1.s3" "$fp_s3_0" "$(cmp_fingerprint tree "select s3 from $DB.d1 order by time;")"
cmp_assert_same "非对齐序列 d2.s1" "$fp_d2_0" "$(cmp_fingerprint tree "select s1 from $DB.d2 order by time;")"
N1=$(null_cnt "$fp_all1")
[ "$N0" = "$N1" ] && pass "null 个数不变（$N0）" || fail "null 个数变化：$N0 → $N1"

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死"

log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
