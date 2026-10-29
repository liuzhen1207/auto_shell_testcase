#!/bin/bash
# ============================================================================
# DT-07 **树转表视图** 的列类型修改（手册「高级功能-树转表视图 2.2」）
#
# 需求点：视图支持 `ALTER VIEW ... ALTER COLUMN col SET DATA TYPE`（V2.0.8 起，仅 FIELD 列，兼容表同表模型）。
#   ① 正确语法建视图：`CREATE VIEW <表库>.<视图> (col TYPE FIELD FROM <测量>) AS <树路径>.**`
#   ② 改 FIELD 列类型成功、`desc` 反映新类型、视图读数按新类型转换；
#   ③ 非 FIELD 列/不兼容类型被拒（701）；
#   ④ 视图 × 底层序列合并：合并后视图读数不变（视图只是映射）。
# 用法： bash dt_view.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_view_${DATA_CONSENSUS}"

VDB=dtvw
SRC=root.dtvwsrc
BASE=$(( ($(date +%s) - 3600) * 1000 ))

# 视图也是表模型语义：`SELECT` 只返回投影列 ⇒ 取值一律按**列名**定位（旧的硬编码列号取到空串，判据变空转）
dt07_vals(){ cmp_tbl_col_vals "select $1 from $VDB.v1 order by time;" "$1"; }
dt07_coltype(){ cmp_tbl_coltype "$VDB.v1" "$1"; }

log "--- 集群准备：三类合并先关 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- ① 建树库（源）+ 表库（视图容器）+ 数据 ---"
sq "create database $SRC;" >/dev/null
sq "create timeseries $SRC.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "create timeseries $SRC.d1.s2 with datatype=DOUBLE, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $SRC.d1(time,s1,s2) values ($(( BASE + 100 )),7,1.5),($(( BASE + 110 )),8,2.5);" >/dev/null
sq "flush;" >/dev/null; sleep 5
sqt "create database $VDB;" >/dev/null 2>&1

log "--- ② 建视图（正确语法）+ 读数 ---"
r=$(sqt "create view $VDB.v1 (s1 INT32 FIELD FROM s1, s2 DOUBLE FIELD FROM s2) as $SRC.d1.**;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ')
printf '%s' "$r" | grep -qi successfully && pass "  建视图成功（$VDB.v1）" || fail "  建视图失败：$(printf '%s' "$r" | cut -c1-160)"
log "  视图列表=$(sqt "show views from $VDB;" 2>&1 | grep -E '^\|' | tr '\n' ' ' | cut -c1-100)"
log "  视图结构=$(sqt "desc $VDB.v1;" 2>&1 | grep -E '^\|' | tr '\n' ' ' | cut -c1-160)"
V0=$(dt07_vals s1); V02=$(dt07_vals s2)
log "  视图读数：s1=$V0 s2=$V02"
# 场景有效性：视图必须真的能读到源库数据（旧版 helper 取到空串 ⇒ 判据空转，本轮已修）
assert_eq "  视图 s1 读数（源库 INT32 7/8）" "$V0" "7|8|"
assert_eq "  视图 s2 读数（源库 DOUBLE 1.5/2.5）" "$V02" "1.5|2.5|"

log "--- ③ 改视图 FIELD 列类型 ---"
r=$(cmp_alter_col "alter view $VDB.v1 alter column s1 set data type DOUBLE;")
ty=$(dt07_coltype s1)
if printf '%s' "$r" | grep -qi successfully && [ "$ty" = "DOUBLE" ]; then
  pass "  ALTER VIEW s1 INT32 → DOUBLE 成功（desc=$ty）"
else
  fail "  改视图列类型失败：ty=$ty resp=$(printf '%s' "$r" | cut -c1-140)"
fi
V1=$(dt07_vals s1)
log "  改后视图 s1 读数=$V1；源序列类型=$(cmp_series_type "$SRC.d1.s1")（视图改类型只动视图 schema，源序列不变）"
assert_eq "  视图读数按新类型呈现（7/8 → 7.0/8.0）" "$V1" "7.0|8.0|"

log "--- ④ 负向：不兼容类型 / 不存在的列 ---"
r=$(cmp_alter_col "alter view $VDB.v1 alter column s2 set data type FLOAT;")
printf '%s' "$r" | grep -qiE 'not compatible|701' && pass "  DOUBLE → FLOAT 被拒绝（$(printf '%s' "$r" | grep -oE '701: .*' | cut -c1-90)）" \
  || fail "  DOUBLE → FLOAT 未被拒绝：$(printf '%s' "$r" | cut -c1-140)"
r=$(cmp_alter_col "alter view $VDB.v1 alter column no_such set data type DOUBLE;")
printf '%s' "$r" | grep -qiE '701|550|not exist' && pass "  不存在的列被拒绝（$(printf '%s' "$r" | cut -c1-100)）" \
  || warn "  不存在列的响应：$(printf '%s' "$r" | cut -c1-120)"

log "--- ⑤ 视图 × 底层序列合并：合并后视图读数不变 ---"
# 源序列仍是 INT32，所以按 INT32 写（视图 s1 已改成 DOUBLE，读出来应是 10.0）
wr=$(sq "insert into $SRC.d1(time,s1,s2) values ($(( BASE + 200 )),10,3.5);" 2>&1 | grep -c successfully)
[ "${wr:-0}" -ge 1 ] && pass "  ⑤ 向源库写入第 3 行成功" || fail "  ⑤ 向源库写入失败（视图改类型不应影响源序列写入）"
sq "flush;" >/dev/null; sleep 5
VB=$(dt07_vals s1); FINS0=$(cmp_inner_finish "$SRC"); TSS0=$(cmp_all_sum "$SRC")
log "  合并前视图读数=$VB（源库布局=$(cmp_lay "$SRC")）"
[ "${TSS0:-0}" -ge 2 ] && pass "  合并起点有 ≥2 个 TsFile（跨副本合计 $TSS0）" \
  || fail "  合并起点 TsFile 只有 ${TSS0:-0} 个（场景无效）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
dl=$(( $(date +%s) + 150 )); ok=0
while (( $(date +%s) < dl )); do
  [ "$(cmp_inner_finish "$SRC")" -gt "$FINS0" ] && [ "$(cmp_all_sum "$SRC")" -lt "$TSS0" ] && { ok=1; break; }; sleep 5
done
sleep 6
VA=$(dt07_vals s1)
log "  合并后视图读数=$VA（源库布局=$(cmp_lay "$SRC") finish=$FINS0→$(cmp_inner_finish "$SRC")）"
[ "$ok" = 1 ] && pass "  底层序列合并完成" || warn "  底层未观察到合并推进（记录）"
assert_eq "  合并前视图读数（含第 3 行 10.0）" "$VB" "7.0|8.0|10.0|"
[ "${VA:-x}" = "${VB:-y}" ] && pass "  合并后视图读数不变（$VA）" || fail "  合并后视图读数变化：$VB → $VA"

log "--- ④' ConfigNode 侧 NPE 取证（若视图改列类型触发 CN NPE，这里打印堆栈便于研发定位）---"
NPE_CNT=0
for h in "${CN[@]}"; do
  n=$(sshx "$h" "grep -c 'NullPointerException' $DB_DIR/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  NPE_CNT=$(( NPE_CNT + ${n:-0} ))
  if [ "${n:-0}" -gt 0 ]; then
    # 只取**第一条**的完整上下文（含前 2 行触发日志 + 后 40 行堆栈），否则上下文会被后续 NPE 行挤掉
    log "    [$h] NPE 条数=$n，完整堆栈（首条）："
    sshx "$h" "grep -n -m 1 -B 2 -A 40 'NullPointerException' $DB_DIR/logs/log_confignode_all.log 2>/dev/null | cut -c1-220" 2>/dev/null | sed 's/^/    | /' >>"$OUT"
    # 首条 NPE 的异常类/首帧摘要，便于与研发比对
    sshx "$h" "grep -m 1 -A 3 'NullPointerException' $DB_DIR/logs/log_confignode_error.log 2>/dev/null | cut -c1-220" 2>/dev/null | sed 's/^/    [err] /' >>"$OUT"
  fi
done
if [ "${NPE_CNT:-0}" -gt 0 ]; then
  fail "  ConfigNode 日志出现 $NPE_CNT 条 NullPointerException（视图改列类型触发的缺陷嫌疑，堆栈已写入用例输出）"
else
  pass "  ConfigNode 日志无 NullPointerException"
fi

log "--- 收尾三件套（本用例故意触发过负向改写，这些预期错误列入 benign）---"
export CMP_LOG_BENIGN_EXTRA='not compatible with the existing one|Can only alter datatype of FIELD|Alter (timeseries|view|table).*(schema regions failed|failed)|Status code: (507|508|701|616)|Column .* does not exist|does not exist'
post_checks "select s1 from $VDB.v1 order by time;" table
cmp_case_finish "" table ""
