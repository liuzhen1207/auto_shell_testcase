#!/bin/bash
# ============================================================================
# DT-09 高可用：合并/改类型期间节点下线（**正常 stop** 为主，另加 kill -9 对照）
#   A) 合并进行中**优雅停** 1 个 DataNode（`stop-datanode.sh`，TERM 信号）→ 重启 → 恢复与追赶
#   B) 优雅停 1 个 ConfigNode → 集群仍可读写/合并（CN 多数派 2/3）→ 重启
#   C) 优雅停 2 个 ConfigNode（3 节点组 quorum=2 ⇒ **真的**无 CN 多数派）→
#      元数据 DDL 必须被拒 / 不得"假成功"，DML 走 DN 数据区共识仍应可用、不得损坏 → 恢复后数据一致
#   D) **改类型期间**停一个 DataNode → 重启后元数据一致（新类型生效）且数据可读
#      （响应里出现 `IndexOutOfBounds` / `out of bounds` = CN procedure 内部崩溃，单独识别并明确 FAIL）
#   E) 对照：合并进行中 `kill -9`（`stop-datanode.sh -f`）一个 DataNode → 重启后数据/类型仍一致
#
# 脚本语义（本轮核实，重要）：`stop-datanode.sh` **不带 `-f` 是 `kill -s TERM`（优雅停）**，
#   带 `-f` 才是 `kill -9`（强制）。早期版本误把 `-f` 当"正常 stop"，已纠正：
#   A~D 用优雅停，E 专门做 force kill 对照。ConfigNode 的 stop-confignode.sh 语义相同。
# 判据：每次故障注入后 ① 集群状态明确（Running/拒绝）；② 数据不丢不坏（指纹/行数与前一致）；
#       ③ 恢复后 sync lag 归零 + 逐个停 DN 副本一致 + 无残留临时文件；④ 日志无 NPE/OOM/越界/overlap。
# 用法： bash dt_ha_stop_nodes.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_ha_stop_nodes_${DATA_CONSENSUS}"

DB=root.dtstop
BASE=$(( ($(date +%s) - 3600) * 1000 ))
VICTIM="${DN[1]}"
CNV1="${CN[1]}"
CNV2="${CN[2]}"
WIN=${CO_MERGE_WAIT_SEC:-120}

dt09_stop_dn(){ local h=$1 mode=${2:-term}
  if [ "$mode" = force ]; then
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  else
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
  dt09_dn_add "$h"     # 记入"已停未起"账本（EXIT trap 兜底，见下方 dt09_restore_stopped）
  wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  $h 停后仍显示 Running"; }
dt09_start_dn(){ local h=$1
  dt09_dn_del "$h"     # 已发出重启命令 ⇒ 出账本（正常路径下 EXIT trap 就是 no-op）
  sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_$h.log 2>&1 </dev/null &" || true
  wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "  $h 未恢复 Running"; }
dt09_stop_cn(){ local h=$1
  sshx "$h" "$CN_DB_DIR/sbin/stop-confignode.sh >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  dt09_cn_add "$h"
  sleep 10; }
# 用法：dt09_start_cn <host> [nowait]  —— nowait = 只发启动命令、不等 CN 全量 Running。
# C 相要把 2 台 CN 一起起回：逐台用默认（等满 ${#CN[@]}）会把第一台白等一个 CLUSTER_READY_TIMEOUT。
dt09_start_cn(){ local h=$1 mode=${2:-wait}
  dt09_cn_del "$h"
  sshx "$h" "nohup $CN_DB_DIR/sbin/start-confignode.sh -d >$CN_DB_DIR/start_cn_${RUN_ID}_$h.log 2>&1 </dev/null &" || true
  [ "$mode" = nowait ] && return 0
  dt09_wait_cn_full || warn "  $h 恢复后 CN 数量未满（$(dt09_cn_running)/${#CN[@]}）"; }
dt09_cn_running(){ sq 'show cluster;' 2>/dev/null | grep -c 'ConfigNode|Running'; }
dt09_wait_cn_full(){ local dl; dl=$(( $(date +%s) + CLUSTER_READY_TIMEOUT ))
  while (( $(date +%s) < dl )); do
    [ "$(dt09_cn_running)" -ge "${#CN[@]}" ] && return 0; sleep 5
  done; return 1; }
# --- "已停未起"账本 + EXIT trap ---------------------------------------------
# 账本用**空格分隔字符串**而不是数组：`set -u` 下空数组的展开在老 bash 上会报 unbound variable。
# 用途有二：
#   ① C 相用**确定性算术**（组内节点数 − 本用例已停数）判断"是否真的失去多数派"——
#      无 CN leader 时 `show cluster` 往往查不到（返回 0），不能拿它当依据；
#   ② 用例在"停掉节点之后、发出重启命令之前"异常退出（被 kill / 被超时 / `set -u` 报错）时，
#      EXIT trap 会把账本里的节点起回来，避免把集群留在半死状态、影响后续用例。
# 正常路径下账本在每次 start 时被清空 ⇒ trap 不做事（也不会在 cluster_stop 之后又去起节点）。
DT09_CN_DOWN=""; DT09_DN_DOWN=""
dt09_cn_add(){ case " $DT09_CN_DOWN " in *" $1 "*) ;; *) DT09_CN_DOWN="${DT09_CN_DOWN:+$DT09_CN_DOWN }$1";; esac; }
dt09_cn_del(){ local h o=""; for h in $DT09_CN_DOWN; do [ "$h" = "$1" ] || o="${o:+$o }$h"; done; DT09_CN_DOWN="$o"; }
dt09_cn_down_n(){ set -- $DT09_CN_DOWN; echo $#; }
dt09_dn_add(){ case " $DT09_DN_DOWN " in *" $1 "*) ;; *) DT09_DN_DOWN="${DT09_DN_DOWN:+$DT09_DN_DOWN }$1";; esac; }
dt09_dn_del(){ local h o=""; for h in $DT09_DN_DOWN; do [ "$h" = "$1" ] || o="${o:+$o }$h"; done; DT09_DN_DOWN="$o"; }
# 进程级探活（不依赖 show cluster / CN 多数派），只用于 trap 兜底
dt09_wait_proc(){ local h=$1 kind=$2 t=${3:-120} dl; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    sshx "$h" "pgrep -f 'com\\.timecho\\.iotdb\\.$kind' >/dev/null 2>&1" >/dev/null 2>&1 && return 0
    sleep 3
  done; return 1; }
dt09_restore_stopped(){
  local h
  [ -n "$DT09_CN_DOWN$DT09_DN_DOWN" ] || return 0
  log "--- [trap] 用例异常结束：起回本用例停掉但尚未发重启命令的节点（CN='${DT09_CN_DOWN:-无}' DN='${DT09_DN_DOWN:-无}'）---"
  for h in $DT09_CN_DOWN; do
    log "  [trap] 起回 ConfigNode $h"
    sshx "$h" "nohup $CN_DB_DIR/sbin/start-confignode.sh -d >$CN_DB_DIR/start_cn_${RUN_ID}_${h}_trap.log 2>&1 </dev/null &" >/dev/null 2>&1 || true
    dt09_wait_proc "$h" ConfigNode 120 || warn "  [trap] $h 的 ConfigNode 进程 120s 内未起来（记录）"
  done
  for h in $DT09_DN_DOWN; do
    log "  [trap] 起回 DataNode $h"
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h}_trap.log 2>&1 </dev/null &" >/dev/null 2>&1 || true
    dt09_wait_proc "$h" DataNode 120 || warn "  [trap] $h 的 DataNode 进程 120s 内未起来（记录）"
  done
  DT09_CN_DOWN=""; DT09_DN_DOWN=""
}
trap 'dt09_restore_stopped' EXIT
dt09_merge_wait(){ local db=$1 fin0=$2 ts0=$3 t=${4:-$WIN} dl ok=0; dl=$(( $(date +%s) + t ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_inner_finish "$db")" -gt "$fin0" ] && [ "$(cmp_all_sum "$db")" -lt "$ts0" ] && { ok=1; break; }
    sleep 5
  done; echo "$ok"; }
# 造 6 个 TsFile（每次 flush 一个 level-0 文件），用于"合并进行中"注入故障
dt09_mkbatch(){ local i
  for i in 1 2 3 4 5 6; do
    sq "insert into $DB.d1(time,s1) values ($(( BASE + i * 1000 )),$i),($(( BASE + i * 1000 + 10 )),$(( i + 100 )));" >/dev/null
    sq "flush;" >/dev/null; sleep 3
  done
  sq "flush;" >/dev/null
  cmp_wait_lay "$DB" "6/0/0/0" 180 >/dev/null || log "  布局未稳定在 6/0/0/0（实际 $(cmp_lay "$DB")，记录）"; }

log "--- 集群准备：三类合并先关；限流便于在合并中注入故障 ---"
EXTRA_CONF="$CMP_EXTRA_WRITE,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare

log "=== A) 合并进行中**优雅停** 1 个 DataNode（$VICTIM，TERM）==="
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
dt09_mkbatch
rows0=$(cmp_rows_series "$DB.d1.s1")
FP0=$(cmp_fp_series "$DB.d1.s1"); CNT0=$(row_sum "$(sq "select count(s1) from $DB.**;")")
FINA=$(cmp_inner_finish "$DB"); TSA=$(cmp_all_sum "$DB")
log "  起点布局=$(cmp_lay "$DB") 可见 $rows0 行 行数=$CNT0（限流 1MB/s ⇒ 合并持续数秒）"
[ "${TSA:-0}" -ge 2 ] && pass "  A: 合并起点有 ≥2 个 TsFile（跨副本合计 $TSA）" || fail "  A: 合并起点只有 ${TSA:-0} 个 TsFile（场景无效）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 3
log "  -> 合并进行中优雅停 $VICTIM（stop-datanode.sh，TERM）"
dt09_stop_dn "$VICTIM" term
sleep 30
log "  停机窗口：布局=$(cmp_lay "$DB") finishes=$FINA→$(cmp_inner_finish "$DB") $VICTIM 状态=$(dn_state "$VICTIM")"
cmp_assert_same "  停 1 个 DN 期间数据指纹（经在线副本）" "$FP0" "$(cmp_fp_series "$DB.d1.s1")"
dt09_start_dn "$VICTIM"
check_sync_lag || fail "  恢复后 sync lag 未归零"
OKA=$(dt09_merge_wait "$DB" "$FINA" "$TSA" 240)
log "  恢复后：布局=$(cmp_lay "$DB") finishes=$FINA→$(cmp_inner_finish "$DB") TsFile=$TSA→$(cmp_all_sum "$DB")"
[ "$OKA" = 1 ] && pass "  A: 优雅停机后合并继续并收敛" || warn "  A: 未观察到收敛（记录）"
cmp_assert_same "  A: 恢复后数据指纹" "$FP0" "$(cmp_fp_series "$DB.d1.s1")"
assert_eq "  A: 恢复后行数" "$(row_sum "$(sq "select count(s1) from $DB.**;")")" "$CNT0"
TMP=$(cmp_tmp_leftover "$DB")
[ "${TMP:-0}" -eq 0 ] && pass "  A: 无残留临时文件" || warn "  A: 有 $TMP 个残留临时文件（记录）"
consistency_check "select s1 from $DB.d1 order by time;" tree

log "=== B) 优雅停 1 个 ConfigNode（$CNV1）⇒ 集群仍应可用 ==="
# 先攒出可合并的文件（否则"合并是否推进"无从观察：A 相已经收敛，只写 1 行不会产生可合并的文件）
cmp_compaction_off
for i in 1 2 3; do
  sq "insert into $DB.d1(time,s1) values ($(( BASE + 200000 + i * 1000 )),$(( 500 + i )));" >/dev/null
  sq "flush;" >/dev/null; sleep 2
done
sleep 3
dt09_stop_cn "$CNV1"
log "  停 $CNV1 后 CN Running 数=$(dt09_cn_running)/${#CN[@]}"
n=$(sq "insert into $DB.d1(time,s1) values ($(( BASE + 90000 )),777);" 2>&1 | grep -c successfully)
[ "${n:-0}" -ge 1 ] && pass "  B: 停 1 个 CN 后写入仍成功（CN 多数派仍在）" || fail "  B: 停 1 个 CN 后写入失败"
FINB=$(cmp_inner_finish "$DB"); TSB=$(cmp_all_sum "$DB")
log "  B: 合并起点 布局=$(cmp_lay "$DB") 文件=$TSB（CN 少 1 个，多数派仍在）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
dl=$(( $(date +%s) + 150 )); okb=0
while (( $(date +%s) < dl )); do
  [ "$(cmp_inner_finish "$DB")" -gt "$FINB" ] && [ "$(cmp_all_sum "$DB")" -lt "$TSB" ] && { okb=1; break; }; sleep 5
done
log "  B: 合并结束 finish=$FINB→$(cmp_inner_finish "$DB") TsFile=$TSB→$(cmp_all_sum "$DB")"
[ "$okb" = 1 ] && pass "  B: 停 1 个 CN 期间合并仍能推进（双信号）" || fail "  B: 停 1 个 CN 期间合并未推进（finishes=$FINB TsFile=$TSB）"
dt09_start_cn "$CNV1"
sleep 10
pass "  B: $CNV1 已重启（CN Running=$(dt09_cn_running)/${#CN[@]}）"

log "=== C) 优雅停 2 个 ConfigNode（3 节点组 quorum=2 ⇒ 真的无 CN 多数派）==="
# 架构事实：DML（INSERT/SELECT）走 **DataNode 侧的数据区共识**，不依赖 ConfigNode 多数派；
# 依赖 CN 的是 schema/分区等元数据操作。所以本相判据不是"写入必须失败"，而是：
#   ① DDL 必须给出明确错误（或成功但元数据真的落地）；② DML 无论成败都要与最终数据一致；③ 恢复后三副本一致。
# 【本轮修正 · DT-09 定性报告 ①】旧版只停 1 台 CN（2/3 Running **仍是多数派**）却在文案里硬编码"（无多数派）"
#   ⇒ 假警报。现在把 CNV1 + CNV2 都停掉：3 节点组 quorum=floor(3/2)+1=2，只剩 1 台 Running ⇒ 真的无多数派；
#   文案按**实际** Running 数条件化输出"有/无多数派"（Running 数用确定性算术 = 组内节点数 − 本用例已停数，
#   不用 show cluster：无 CN leader 时它可能什么都查不到，见文件上方账本注释）。
NC=${#CN[@]}; CQ=$(( NC / 2 + 1 ))
# 基线必须在**健康窗口**采集：无多数派窗口里 schema 取数可能不可用（721 Fetch Schema failed），读数不可信
FP_C0=$(cmp_fp_series "$DB.d1.s1"); ROW_C0=$(cmp_rows_series "$DB.d1.s1")
log "  C 相注入前（CN 全健康）：$ROW_C0 行，指纹已记录"
# 无多数派窗口里的 SQL 必须有上限：CN 无 leader 时客户端可能一直等，不能让整条用例卡满 SQL_TIMEOUT_SEC(600s)
SQL_SAVE=$SQL_TIMEOUT_SEC; SQL_TIMEOUT_SEC=${DT09_NOMAJ_SQL_TIMEOUT_SEC:-180}
dt09_stop_cn "$CNV1"
dt09_stop_cn "$CNV2"
c_down=$(dt09_cn_down_n); c_run=$(( NC - c_down ))
c_maj=0; [ "$c_run" -ge "$CQ" ] && c_maj=1
if [ "$c_maj" = 1 ]; then c_state="CN 多数派仍在（$c_run/$NC ≥ quorum=$CQ）"; else c_state="无 CN 多数派（$c_run/$NC < quorum=$CQ）"; fi
log "  停 $CNV1 + $CNV2 后：$c_state（本用例已停 CN 数=$c_down；该窗口不再用 show cluster 观测，避免无 leader 时的长等待）"
w=$(sq "insert into $DB.d1(time,s1) values ($(( BASE + 99000 )),888);" 2>&1 | tr '\n' ' ' | cut -c1-140)
log "  $c_state 时 DML 写入响应：$w"
if printf '%s' "$w" | grep -qiE 'successfully'; then
  ROW_C1=$(cmp_rows_series "$DB.d1.s1")
  # 写入确认到可读可能有极短延迟：最多轮询 15s 等它可见
  dl=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < dl )); do
    [ "${ROW_C1:-0}" -ge "$(( ${ROW_C0:-0} + 1 ))" ] && break
    sleep 2; ROW_C1=$(cmp_rows_series "$DB.d1.s1")
  done
  pass "  C: $c_state 时 DML 写入成功（数据区共识在 DN 上，符合架构）"
  if [ "${ROW_C1:-0}" -ge "$(( ${ROW_C0:-0} + 1 ))" ]; then
    assert_eq "  C: 写入真的落地（行数 = 健康基线 +1）" "${ROW_C1:-0}" "$(( ${ROW_C0:-0} + 1 ))"
  else
    # 窗口内读数不可信（无多数派时 schema 取数可能失败 ⇒ 行数读成 0）时**不**据此判"写丢"：
    # 落地性改由 CN 恢复后的收口断言判定（真丢了那里必然 FAIL）；窗口内的指纹比对同理后移。
    warn "  C: $c_state 窗口内行数读成 ${ROW_C1:-0}（健康基线 ${ROW_C0:-0}）⇒ 窗口读数不可信，写入落地性改由 CN 恢复后收口"
  fi
else
  pass "  C: $c_state 时 DML 写入被明确拒绝（$(printf '%s' "$w" | grep -oE '[0-9]{3}: [^ ]*' | head -1)）"
fi
# 元数据（DDL）操作依赖 CN：必须给出明确结果，且不得"报成功却没落地"
ddl=$(sq "create timeseries $DB.d9probe.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tr '\n' ' ' | cut -c1-150)
log "  $c_state 时 DDL 响应：$ddl"
if printf '%s' "$ddl" | grep -qiE 'IoTDBSQLException|[0-9]{3}: '; then
  if [ "$c_maj" = 1 ]; then
    warn "  C: $c_state，DDL 却被拒（记录）：$(printf '%s' "$ddl" | grep -oE '[0-9]{3}: [^ ]*' | head -1)"
  else
    pass "  C: $c_state 时 DDL 被明确拒绝（$(printf '%s' "$ddl" | grep -oE '[0-9]{3}: [^ ]*' | head -1)）"
  fi
elif printf '%s' "$ddl" | grep -qi successfully; then
  if [ "$c_maj" = 1 ]; then
    pass "  C: $c_state，DDL 报成功（符合预期；收口校验元数据是否真的落地）：$ddl"
  else
    warn "  C: $c_state 时 DDL 报成功（收口校验元数据是否真的落地）：$ddl"
  fi
elif [ -z "$(printf '%s' "$ddl" | tr -d '[:space:]')" ]; then
  warn "  C: $c_state 时 DDL 在 ${SQL_TIMEOUT_SEC}s 内无任何响应（客户端挂起；收口以 CN 恢复后的元数据为准）"
else
  warn "  C: DDL 响应不明确：$ddl"
fi
r=$(sq "select s1 from $DB.d1 order by time;" 2>&1 | data_rows | wc -l | tr -dc '0-9')
[ "${r:-0}" -ge 1 ] && pass "  C: $c_state 时读仍可用（可见 $r 行）" || warn "  C: $c_state 时读返回 $r 行（记录）"
SQL_TIMEOUT_SEC=$SQL_SAVE
# ---- C 相收尾：**两台停掉的 CN 都必须起回来**（先起一台即恢复多数派）----
# 用 nowait 并发启动再统一等待：逐台用默认模式时，第一台会一直等到"CN 全量 3/3"而白等一个 CLUSTER_READY_TIMEOUT。
dt09_start_cn "$CNV1" nowait
dt09_start_cn "$CNV2" nowait
if ! dt09_wait_cn_full; then
  okproc=1
  for h in "$CNV1" "$CNV2"; do dt09_wait_proc "$h" ConfigNode 60 || okproc=0; done
  [ "$okproc" = 1 ] && warn "  C: 两台 CN 进程已起，但 show cluster 未在 ${CLUSTER_READY_TIMEOUT}s 内数满（$(dt09_cn_running)/$NC，记录）" \
    || fail "  C: CN 未恢复（进程级探活失败；show cluster=$(dt09_cn_running)/$NC）"
fi
sleep 15
check_sync_lag || fail "  CN 恢复后 sync lag 未归零"
log "  C 相 CN 恢复后：Running=$(dt09_cn_running)/$NC（期望 $NC/$NC）"
# 数据收口（恢复后读数可信）：报成功的写入必须落地、被拒的写入必须没落地，且都必须与健康基线自洽
ROW_C2=$(cmp_rows_series "$DB.d1.s1"); FP_C2=$(cmp_fp_series "$DB.d1.s1")
if printf '%s' "$w" | grep -qiE 'successfully'; then
  assert_eq "  C: CN 恢复后行数 = 健康基线 +1（写入确实落地）" "${ROW_C2:-0}" "$(( ${ROW_C0:-0} + 1 ))"
  [ "$FP_C2" != "$FP_C0" ] && pass "  C: CN 恢复后指纹含新行（写入未被丢弃）" \
    || fail "  C: CN 恢复后指纹等于健康基线（写入丢了）"
else
  assert_eq "  C: CN 恢复后行数 = 健康基线（被拒的写入未落地）" "${ROW_C2:-0}" "${ROW_C0:-0}"
  cmp_assert_same "  C: CN 恢复后指纹与健康基线一致（被拒的写入未落地、无损坏）" "$FP_C0" "$FP_C2"
fi
# DDL 的一致性收口：报过成功就必须真的存在；报错就必须不存在
has9=$(cmp_series_type "$DB.d9probe.s1")
if printf '%s' "$ddl" | grep -qi successfully; then
  [ "$has9" = "INT32" ] && pass "  C: 报成功的 DDL 在 CN 恢复后确实存在（d9probe=INT32）" \
    || fail "  C: DDL 报成功但 CN 恢复后查不到序列（type=$has9，元数据丢失）"
else
  [ -z "$has9" ] && pass "  C: 被拒的 DDL 在 CN 恢复后确实不存在" \
    || warn "  C: DDL 报错但 CN 恢复后序列存在（type=$has9，记录）"
fi

log "=== D) 改类型期间优雅停一个 DataNode ⇒ 恢复后元数据一致 ==="
sq "create timeseries $DB.d2.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $DB.d2(time,s1) values ($(( BASE + 100 )),5),($(( BASE + 110 )),6);" >/dev/null
sq "flush;" >/dev/null; sleep 4
# 这个 DN 是在**后台子 shell** 里停的：子 shell 里调 dt09_dn_add 写不回父 shell 的账本，
# 所以由父 shell 先记账 → 若用例在"停掉之后、起回之前"异常退出，EXIT trap 仍能把它起回来。
dt09_dn_add "$VICTIM"
( sleep 0.3; dt09_stop_dn "$VICTIM" term >/dev/null 2>&1 ) &
dp=$!
r=$(cmp_alter_ts "$DB.d2.s1" DOUBLE)
wait $dp
ty=$(cmp_series_type "$DB.d2.s1")
log "  改类型响应：$(printf '%s' "$r" | cut -c1-120)；当前类型=$ty（$VICTIM 状态=$(dn_state "$VICTIM")）"
# 【本轮修正 · DT-09 定性报告 ②】判据**保留**（期望 DOUBLE 是正确设计预期），但把响应里的
# `IndexOutOfBoundsException` / `out of bounds` **单独识别**为"产品内部错误"，给出明确 FAIL 文案，
# 便于一眼区分"DDL 被优雅拒绝/没生效"与"CN procedure 下标越界崩溃"：
#   CN 侧 AlterTimeSeriesDataTypeProcedure$1.processResponseOfOneDataNode 用 subStatus 的长度去索引
#   consensusGroupIdList（请求里只有 1 个 region，DN 停机窗口内却往 subStatus 里多补了一条
#   INTERNAL_SERVER_ERROR/InterruptedException）⇒ 越界 → procedure rollback → 本应"换副本重试"的逻辑被跳过。
if printf '%s' "$r" | grep -qiE 'IndexOutOfBounds|out of bounds'; then
  fail "  D: 产品内部错误——CN procedure 下标越界（不是『DDL 被优雅拒绝/没生效』，是 CN 内部崩溃）：$(printf '%s' "$r" | tr '\n' ' ' | cut -c1-160)"
  log "     ⇒ 特征栈：ProcedureExecutor:496 ERROR - CODE-BUG:pid=… ALTER_TIME_SERIES_DATA_TYPE + IndexOutOfBoundsException @ AlterTimeSeriesDataTypeProcedure.java:210；procedure 已 rollback ⇒ 类型不会变"
else
  log "  D: 改类型响应未出现越界/内部错误标记"
fi
dt09_start_dn "$VICTIM"
sleep 10
ty2=$(cmp_series_type "$DB.d2.s1")
[ "$ty2" = "DOUBLE" ] && pass "  D: 恢复后元数据一致，类型仍为 DOUBLE" || fail "  D: 恢复后类型=$ty2（期望 DOUBLE）"
for h in "${DN[@]}"; do
  v=$(sq_node "$h" "select s1 from $DB.d2 order by time;" 2>/dev/null | data_rows | wc -l | tr -dc '0-9')
  [ "${v:-0}" -ge 2 ] && pass "  D: 经 $h 可见 2 行" || fail "  D: 经 $h 只看到 ${v:-0} 行"
done

log "=== E) 对照：合并进行中 kill -9 一个 DataNode ⇒ 重启后仍需一致 ==="
cmp_compaction_off   # 写入期间必须关掉合并，否则基线之后没有可合并的文件（DT-03 踩过的坑）
sq "create timeseries $DB.d3.s1 with datatype=DOUBLE, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
for i in 1 2 3 4; do
  sq "insert into $DB.d3(time,s1) values ($(( BASE + 200 + i * 100 )),$i.5);" >/dev/null
  sq "flush;" >/dev/null; sleep 3
done
sq "flush;" >/dev/null; sleep 4
FP3=$(cmp_fp_series "$DB.d3.s1"); ROW3=$(cmp_rows_series "$DB.d3.s1")
FINE=$(cmp_inner_finish "$DB"); TSE=$(cmp_all_sum "$DB")
log "  E: 起点布局=$(cmp_lay "$DB") 文件=$TSE 值=$(cmp_vals_series "$DB.d3.s1" 4)"
[ "${TSE:-0}" -ge 2 ] && pass "  E: 合并起点有 ≥2 个 TsFile（$TSE）" || fail "  E: 合并起点只有 ${TSE:-0} 个 TsFile（场景无效）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 2
log "  -> 合并进行中 kill -9 $VICTIM（stop-datanode.sh -f）"
dt09_stop_dn "$VICTIM" force
sleep 20
log "  强杀窗口：布局=$(cmp_lay "$DB") finishes=$FINE→$(cmp_inner_finish "$DB") $VICTIM 状态=$(dn_state "$VICTIM")"
cmp_assert_same "  强杀期间数据指纹（经在线副本）" "$FP3" "$(cmp_fp_series "$DB.d3.s1")"
dt09_start_dn "$VICTIM"
check_sync_lag || fail "  E: 强杀恢复后 sync lag 未归零"
OKE=$(dt09_merge_wait "$DB" "$FINE" "$TSE" 240)
log "  恢复后：布局=$(cmp_lay "$DB") finishes=$FINE→$(cmp_inner_finish "$DB") TsFile=$TSE→$(cmp_all_sum "$DB")"
[ "$OKE" = 1 ] && pass "  E: 强杀恢复后合并继续并收敛" || warn "  E: 未观察到收敛（记录）"
cmp_assert_same "  E: 强杀恢复后数据指纹" "$FP3" "$(cmp_fp_series "$DB.d3.s1")"
assert_eq "  E: 强杀恢复后行数" "$(cmp_rows_series "$DB.d3.s1")" "$ROW3"
TMPE=$(cmp_tmp_leftover "$DB")
[ "${TMPE:-0}" -eq 0 ] && pass "  E: 无残留临时文件" || warn "  E: 有 $TMPE 个残留临时文件（记录）"
consistency_check "select s1 from $DB.d3 order by time;" tree

log "--- 收尾三件套（停机/无多数派的预期错误列入 benign）---"
# 【判读提示 · DT-09 定性报告 ③ —— 本用例**不**改 lib/common.sh，只在此说明】
# check_logs 对每个节点**同时** grep `*<role>*all*.log` 与 `*<role>*error*.log`（common.sh:615-618），
# 而 ERROR 级日志会同时写进这两个文件，于是**同一个异常**（同机 + 同异常首行 + 同一毫秒时间戳）
# 被计成 2 条。本轮 RC8 报的 "confignode 192.168.99.77 日志出现 2 条异常" 实为 **1 条**（D 相那个越界）。
# ⇒ 看到 "(N 条异常)" 先按 N ≈ 2 ×（不同异常个数）折算；去重补丁已作为建议提交（回复里给出行号与影响面）。
log "  注：日志检查对 all + error 两份文件分别计数，同一异常会被算成 2 条（本用例刻意不改 lib）"
# C 相现在**真的**制造"无 CN 多数派"（3 节点停 2 台），窗口内必然出现"取不到 CN leader / 连不上 CN"的
# 预期噪声，故把这类**明确由本相故意注入的故障**列入 benign；
# 注意：**不得**把 IndexOutOfBoundsException 列进来 —— 那是 D 相要抓的产品真缺陷。
export CMP_LOG_BENIGN_EXTRA='Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|ConfigNode.*(unavailable|not available)|Cannot.*majority|no leader|Failed to fetch schema|721: Fetch Schema failed|Read-only file system|leader.*(not found|unknown)|ServiceUnavailable|LeaderNotFoundException|NotLeaderException|Failed to get (the )?leader|Failed to connect to (the )?ConfigNode|Cannot connect to (the )?ConfigNode'
post_checks "select s1 from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
