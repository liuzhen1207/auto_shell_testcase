#!/bin/bash
# ============================================================================
# 纯桩逻辑验证：任务 A（落盘感知的等待口径 = quorum 放行）+ 任务 B（PHASE 分段时间埋点）
#
#   · **绝不 source 真实 lib**：只按"函数声明行 → 下一个列 0 行"把被测函数体从 lib/*.sh 里
#     **抽出来**（extract_fn），在自定义的假 pass/fail/warn/log、假 sq/sq_node/sshx/
#     ttl_close_cnt/cmp_lay/cmp_su、假时钟（`date +%s` 走虚拟秒、`sleep N` 推进虚拟秒）下运行。
#     ⇒ 秒级完成、不连集群、不装任何东西。
#   · 三条路径：① 三副本全达标 ⇒ 最小等待后立即放行（无 WARN）
#              ② 仅 1 个副本达标 ⇒ 最小等待后放行 + WARN + 打印逐副本实测值
#              ③ 0 个副本达标 ⇒ 等满窗口 + WARN"场景未成立"
#     另验证：CMP_CLOSE_QUORUM=3 能退回旧语义、CMP_CLOSE_MIN_WAIT_SEC 生效、
#             cmp_wait_lay / cmp_wait_su 同口径、PHASE 汇总行与 CSV message（列数不变）。
#   · 用法： bash tools/selftest_waitquorum_stub.sh      （不需要集群）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
LIB_CMP="$SKILL/lib/cmp.sh"
LIB_COMMON="$SKILL/lib/common.sh"
ok=0; bad=0
pass_c(){ ok=$((ok+1)); printf '  [ok] %s\n' "$1"; }
fail_c(){ bad=$((bad+1)); printf '  [FAIL] %s\n' "$1"; }
chk_eq(){ if [ "$2" = "$3" ]; then pass_c "$1（=$3）"; else fail_c "$1：实际[$2] 期望[$3]"; fi; }
chk_has(){ if printf '%s' "$2" | grep -qF -- "$3"; then pass_c "$1"; else fail_c "$1：[$2] 里没有 [$3]"; fi; }
chk_nhas(){ if printf '%s' "$2" | grep -qF -- "$3"; then fail_c "$1：不该出现 [$3]（[$2]）"; else pass_c "$1"; fi; }
chk_ge(){ if [ "$2" -ge "$3" ]; then pass_c "$1（=$2）"; else fail_c "$1：实际[$2] 期望 >=$3"; fi; }

echo "=== 0) 假时钟 / 假断言 / 假远端 ==="
FAKE_NOW=1700000000
date(){ if [ "${1:-}" = "+%s" ]; then printf '%s\n' "$FAKE_NOW"; else command date "$@"; fi; }
sleep(){ FAKE_NOW=$(( FAKE_NOW + ${1:-1} )); }
LOG=""; WARN=""; PASS=""; FAIL=""
log(){  LOG="${LOG}$*"$'\n'; }
warn(){ WARN="${WARN}$*"$'\n'; LOG="${LOG}WARN $*"$'\n'; }
pass(){ PASS="${PASS}$*"$'\n'; }
fail(){ FAIL="${FAIL}$*"$'\n'; }
reset_out(){ LOG=""; WARN=""; PASS=""; FAIL=""; }
n_warn(){ printf '%s' "$WARN" | grep -c . ; }
DN=(192.168.99.77 192.168.99.78 192.168.99.79)
CN=(192.168.99.77)
sq(){ :; }
sq_node(){ :; }
sshx(){ :; }
ttl_close_cnt(){ local h=$1
  case "${CLOSE_MODE:-none}" in
    all) printf '%s\n' "${CLOSE_MIN:-0}" ;;
    one) if [ "$h" = "${DN[1]}" ]; then printf '%s\n' "${CLOSE_MIN:-0}"; else printf '0\n'; fi ;;
    *)   printf '0\n' ;;
  esac; }
cmp_lay(){ printf '%s' "${LAY_SPEC:-}"; }
cmp_su(){ printf '%s' "${SU_SPEC:-}"; }
pass_c "假时钟/假断言/假远端就绪（DN=${#DN[@]} 个，绝不 source 真实 lib）"

echo "=== 1) 从 lib 抽出被测函数（不 source）==="
extract_fn(){ local file=$1 fn=$2
  awk -v fn="$fn" '
    !on { if (index($0, fn"(){") == 1) on=1; else next }
    on  { if (seen && $0 ~ /^[^ \t]/) exit; print; seen=1 }' "$file"; }
load_fn(){ local file=$1 fn=$2 body
  body=$(extract_fn "$file" "$fn")
  if [ -z "$body" ]; then fail_c "抽取函数 $fn 失败（$file）"; return 1; fi
  eval "$body" || fail_c "eval 函数 $fn 失败"
  pass_c "已抽取 $fn（$(printf '%s\n' "$body" | wc -l | tr -d ' ') 行，未 source lib）"; }
load_fn "$LIB_CMP" cmp_quorum_verdict
load_fn "$LIB_CMP" cmp_wait_close
load_fn "$LIB_CMP" cmp_wait_lay
load_fn "$LIB_CMP" cmp_wait_su
for f in cmp_phase_reset cmp_phase_put cmp_phase_rec cmp_phase_open_of cmp_phase_recorded cmp_phase_del \
         cmp_phase_begin cmp_phase_end cmp_phase_summary post_checks write_result cmp_case_finish; do
  load_fn "$LIB_COMMON" "$f"
done
CMP_PHASE_OPEN=""; CMP_PHASE_LOG=""
CMP_CLOSE_QUORUM=1; CMP_CLOSE_MIN_WAIT_SEC=10

echo "=== 2) 路径① 三副本全达标 ⇒ 最小等待后立即放行（不等满窗口）==="
CLOSE_MODE=all; CLOSE_MIN=7; FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_close root.stub1 7 90 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "① 放行（rc=0）" "$rc" 0
chk_eq "① 耗时 = 最小等待 12s（不是窗口 90s）" "$used" 12
chk_eq "① 无 WARN（三副本都达标）" "$(n_warn)" 0
chk_has "① 打印逐副本实测值" "$LOG" "77:7 78:7 79:7"

echo "=== 3) 路径② 仅 1 个副本达标 ⇒ 最小等待后放行 + WARN + 逐副本值 ==="
CLOSE_MODE=one; CLOSE_MIN=7; FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_close root.stub2 7 90 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "② 放行（rc=0）" "$rc" 0
chk_eq "② 耗时 = 最小等待 12s" "$used" 12
chk_ge "② 有 WARN（未达标副本只 warn）" "$(n_warn)" 1
chk_has "② WARN 标注达标副本数" "$WARN" "达标副本 1/3"
chk_has "② WARN 注明 V2 落盘/close 时序" "$WARN" "V2"
chk_has "② 打印逐副本实测值（未达标副本为 0）" "$LOG" "77:0 78:7 79:0"

echo "=== 4) 路径③ 0 个副本达标 ⇒ 等满窗口 + WARN『场景未成立』==="
CLOSE_MODE=none; FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_close root.stub3 7 90 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "③ 超时返回 1" "$rc" 1
chk_eq "③ 等满窗口 90s" "$used" 90
chk_has "③ WARN 含『场景未成立』" "$WARN" "场景未成立"
chk_has "③ WARN 附逐副本实测值" "$WARN" "77:0 78:0 79:0"

echo "=== 5) 口径可回退：CMP_CLOSE_QUORUM=3（旧『三副本全达标』）+ 最小等待可调 ==="
CLOSE_MODE=one; CMP_CLOSE_QUORUM=3; FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_close root.stub4 7 90 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "quorum=3 时 1 个达标不放行（rc=1）" "$rc" 1
chk_eq "quorum=3 时等满窗口" "$used" 90
CMP_CLOSE_QUORUM=1; CLOSE_MODE=all; CMP_CLOSE_MIN_WAIT_SEC=30; FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_close root.stub5 7 90 >/dev/null; used=$(( FAKE_NOW - used0 ))
chk_eq "CMP_CLOSE_MIN_WAIT_SEC=30 生效" "$used" 30
CMP_CLOSE_MIN_WAIT_SEC=10

echo "=== 6) cmp_wait_lay / cmp_wait_su 同口径（逐副本实测值 + quorum 放行）==="
LAY_SPEC="77:2/0/0/0 78:0/0/0/0 79:0/0/0/0 "; FAKE_NOW=1700000000; reset_out
cmp_wait_lay root.stub6 "2/0/0/0" 150 >/dev/null; rc=$?
chk_eq "lay：1 个副本达标即放行（rc=0）" "$rc" 0
chk_has "lay：打印逐副本布局" "$LOG" "77:2/0/0/0 78:0/0/0/0 79:0/0/0/0"
chk_ge "lay：未达标副本 WARN" "$(n_warn)" 1
FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_lay root.stub7 "0/1/0/0" 150 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "lay：0 个达标 ⇒ 等满窗口 + 返回 1" "$rc|$used" "1|150"
chk_has "lay：WARN 含『场景未成立』" "$WARN" "场景未成立"
SU_SPEC="77:8/2 78:8/0 79:8/0 "; FAKE_NOW=1700000000; reset_out
cmp_wait_su root.stub8 "8/2" 150 >/dev/null; rc=$?
chk_eq "su：1 个副本达标即放行（rc=0）" "$rc" 0
chk_has "su：打印逐副本计数" "$LOG" "77:8/2 78:8/0 79:8/0"
FAKE_NOW=1700000000; reset_out
used0=$FAKE_NOW; cmp_wait_su root.stub9 "8/9" 150 >/dev/null; rc=$?; used=$(( FAKE_NOW - used0 ))
chk_eq "su：0 个达标 ⇒ 等满窗口 + 返回 1" "$rc|$used" "1|150"

echo "=== 7) PHASE 埋点：begin/end + log + 汇总 + 复用不重复计时 ==="
cmp_phase_reset; FAKE_NOW=1700000000; reset_out
cmp_phase_begin prepare "集群准备";           sleep 210; cmp_phase_end prepare
cmp_phase_begin post_sync "收尾三件套 1/3";    sleep 12;  cmp_phase_end post_sync
cmp_phase_begin post_consistency "收尾 2/3";   sleep 0;   cmp_phase_end post_consistency
cmp_phase_begin teardown "用例收尾"                      # 外层：手工包
cmp_phase_begin teardown "用例收尾"                      # 内层：必须复用（嵌套）
sleep 48
cmp_phase_end teardown
cmp_phase_end teardown                                   # 只有最外层结束才记账
SUM=$(cmp_phase_summary 611)
chk_eq "PHASE 汇总行格式" "$SUM" "prepare=210s post_sync=12s post_consistency=0s teardown=48s total=611s"
chk_has "段结束即 log \"[PHASE] <名> <秒>s\"" "$LOG" "[PHASE] 集群准备 210s"
chk_has "嵌套 begin 复用（不重复计时）" "$LOG" "复用已有计时"
chk_eq "同一 key 在汇总里只出现一条" "$(printf '%s\n' "$CMP_PHASE_LOG" | grep -c '^teardown|')" 1
cmp_phase_begin teardown "用例收尾"; cmp_phase_end teardown
chk_eq "已结束的 key 再 begin/end 不新增记录" "$(printf '%s\n' "$CMP_PHASE_LOG" | grep -c '^teardown|')" 1
printf '  PHASE 汇总示例: %s\n' "$SUM"

echo "=== 8) 自动包段：post_checks 三小节 / cmp_cluster_prepare 整段 / cmp_case_finish + CSV ==="
check_sync_lag(){ sleep 5; }; consistency_check(){ sleep 7; }; check_logs(){ sleep 3; }
cmp_align_version(){ sleep 1; }; cluster_stop(){ sleep 2; }; cluster_clean(){ sleep 3; }
cluster_write_conf(){ sleep 4; }; cluster_start(){ sleep 5; }; backup_logs(){ sleep 1; }
cmp_phase_reset; FAKE_NOW=1700000000; reset_out
post_checks "select count(s1) from x.**;" tree
PS=$(cmp_phase_summary 0)
chk_has "post_checks 三小节各自成段" "$PS" "post_sync=5s post_consistency=7s post_logs=3s"
cmp_phase_reset; FAKE_NOW=1700000000
SKIP_LIFECYCLE=0 cmp_cluster_prepare
chk_has "cmp_cluster_prepare 整段 = prepare" "$(cmp_phase_summary 0)" "prepare=18s"
OUTDIR=/tmp/cs_stub_out; rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
RUN_ID=stub; CASE=stub_case; BUILD_TAG=vSTUB; ART=/tmp/stub_art
CONSENSUS_CLASS=org.apache.iotdb.consensus.iot.IoTConsensus
fail_flag=0; v_warnMessage=""; start_epoch=$FAKE_NOW
cmp_phase_reset; FAKE_NOW=1700000000; reset_out
cmp_cluster_prepare                       # prepare
post_checks "select 1;" tree              # post_sync / post_consistency / post_logs
fail_flag=1; v_warnMessage="stub 场景告警"
cmp_case_finish "" tree ""                # teardown（备份日志 + 停集群 + 写结果）
LINE=$(tail -1 "$OUTDIR/test_result.csv")
chk_eq "CSV 列数不变（9）" "$(printf '%s' "$LINE" | awk -F, '{print NF}')" 9
chk_has "CSV message 含 PHASE 汇总" "$LINE" "PHASE: prepare=18s"
chk_has "CSV message 含 teardown 与 total" "$LINE" "teardown="
chk_has "CSV message 仍保留原 v_warnMessage" "$LINE" "stub 场景告警"
chk_has "PHASE 也打印到用例日志（结束时汇总）" "$LOG" "PHASE: prepare=18s"
printf '  CSV 行示例: %s\n' "$LINE"
printf '  CSV 表头: %s\n' "$(head -1 "$OUTDIR/test_result.csv")"

echo
echo "=== 纯桩自检汇总：ok=$ok failed=$bad ==="
[ "$bad" = "0" ] || exit 1
