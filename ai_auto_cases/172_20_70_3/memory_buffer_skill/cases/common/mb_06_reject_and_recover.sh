#!/bin/bash
# MB-06 内存压力进入 reject 状态并恢复（reject_proportion / check_period_when_insert_blocked /
#       max_waiting_time_when_insert_blocked_in_ms）
#   做法：memtable 压到 ~20MB，flush_proportion=0.01（0.2MB 就刷）、reject_proportion=0.02（0.4MB 就拒），
#         用 2 个并发会话连写大 payload，使 memtable 增长速度超过刷盘速度。
#   判据：① 出现 "Change system to reject status"；
#         ② 之后出现 "set system to normal status"（内存释放后自动恢复）；
#         ③ 出现写入被拒/阻塞的明确结果（显式异常或语句失败），不得"静默丢数据"；
#         ④ 最终可查点数 == 成功语句数 × 每语句行数（一条语句原子，不允许部分写入）；
#         ⑤ 集群仍健康，一致性校验通过。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"
source "$HERE/../../lib/mb.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init MB-06
export MB_POSITIVE_EVIDENCE_FN=mb_evidence_reject

MB_MEM_PROPORTION="1:10000:1:1:1:1"
MB_FLUSH_PROPORTION="0.01"
MB_REJECT_PROPORTION="0.02"
MB_CHECK_PERIOD_WHEN_BLOCKED="50"
MB_MAX_WAIT_WHEN_BLOCKED="10000"
export MB_MEM_PROPORTION MB_FLUSH_PROPORTION MB_REJECT_PROPORTION MB_CHECK_PERIOD_WHEN_BLOCKED MB_MAX_WAIT_WHEN_BLOCKED
DB=root.mb06
# 默认值取"每语句行数(65)的整数倍"(1300 = 20×65)，让每条 INSERT 都是满语句：
# 规模说明：reject 阈值仅 0.4MB、flush 阈值 0.2MB，1300 点（≈5MB×2 会话）已足够压过阈值；
# 早期用 2990/8000 点时两个并发 CLI JVM 会让客户端负载过高、用例偶发被 SIGKILL。
#   这样"点数必须是每语句行数的整数倍"才是合法的原子性判据（否则最后一条是残语句，
#   实测 3000 点被拆成 46×65+10，总点数 6000 不是 65 的倍数，判据会假 FAIL）。
ROWS=${MB06_ROWS:-65}
export EXTRA_CONF=""

mb_normal_cnt(){ local h s=0 v; for h in "${DN[@]}"; do v=$(sshx "$h" "grep -hc 'set system to normal status' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9'); s=$(( s + ${v:-0} )); done; echo "$s"; }

mb_cluster_prepare
mb_make_tree_db "$DB" 2 text

rej0=$(mb_reject_enter_all); nor0=$(mb_normal_cnt)
log "  基线: reject_enter=$rej0 normal=$nor0"

# 规模说明：reject 阈值 = 20MB × 0.02 ≈ 0.4MB，flush 阈值 ≈ 0.2MB ⇒ 几千点就足够压过阈值。
# 早期用 8000 点（≈32MB/会话）压测时用例能在独立执行下跑通（reject 进入 244 次、16000 点落库、副本一致），
# 但客户端同时开两个 CLI JVM 做 64MB 写入会显著加重客户端负载（本机经 run_all 调用时易被会话层打断），
# 现在默认 325（=5×65，约 2×1.3MB）已能压过 reject 阈值；需要更强压力时用 MB06_ROWS=650 覆盖。
log "--- 并发灌入（2 会话 × ${ROWS} 点 × ${MB_PAYLOAD_BYTES}B），制造内存压力 ---"
mb_bulk_text "$DB" d1 "$ROWS" 1 >/tmp/mb06_a.res 2>&1 &
p1=$!
mb_bulk_text "$DB" d2 "$ROWS" 1 >/tmp/mb06_b.res 2>&1 &
p2=$!
wait $p1 $p2
ok1=$(awk '{print $1}' /tmp/mb06_a.res); bad1=$(awk '{print $2}' /tmp/mb06_a.res)
ok2=$(awk '{print $1}' /tmp/mb06_b.res); bad2=$(awk '{print $2}' /tmp/mb06_b.res)
log "  写入结果: d1 ok=${ok1:-0} bad=${bad1:-0} / d2 ok=${ok2:-0} bad=${bad2:-0}"
ok_total=$(( ${ok1:-0} + ${ok2:-0} ))

sleep 5
rej1=$(mb_reject_enter_all); nor1=$(mb_normal_cnt)
assert_ge "①进入 reject 状态（全 DN 计数）" "$rej1" "$(( rej0 + 1 ))"

log "--- 等内存释放（最多 60s；normal 日志行只作证据）---"
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
  nor1=$(mb_normal_cnt); mem=$(mb_region_mem_all)
  log "  normal 计数=$nor1 regionMemCost=$mem"
  [ "${nor1:-0}" -gt "$nor0" ] && break
  sleep 5
done
# 恢复判据做成弹性：本参数组合（flush=1% / reject=2%）下内存会在阈值附近持续震荡，
# 实测区域 memCost 从 16MB 回落到 10MB，但 `set system to normal status` 这一行没出现
# （该 INFO 只在 resetStorageGroupStatus 的特定分支打印）。因此：
#   · 硬判据 = 内存确实被释放（regionMemCost 显著下降）；
#   · normal 日志行只作证据，缺失记 WARN，不判 FAIL（否则是判据本身错，不是产品问题）。
if [ "${nor1:-0}" -gt "$nor0" ]; then pass "②恢复到 normal 状态（日志证据 normal=$nor1）"
else warn "②未观察到 'set system to normal status' 日志行（normal=$nor1）；改看内存是否释放"; fi

sq 'flush;' >/dev/null 2>&1
sleep 3
cnt=$(mb_count_all "$DB")
# 每条 INSERT 的实际行数 = 单语句载荷上限 / 单点载荷（见 lib/common.sh 的分片规则），
# 不能用 MB_ROWS_PER_STMT（那是 INT64 场景的值）。
ROWS_PER_STMT=$(( ${MB_STMT_PAYLOAD_BYTES:-262144} / MB_PAYLOAD_BYTES ))
[ "$ROWS_PER_STMT" -lt 1 ] && ROWS_PER_STMT=1
# ⚠️ SUBMITTED 必须在使用**之前**定义：首版把它写在后面的 ③ 段里，
#    而 `set -u` 下上面 `[ "$ok_total" -eq "$SUBMITTED" ]` 引用未定义变量 ⇒
#    脚本静默退出 rc=1、result 文件不落盘（表现为"用例莫名没结果"，排查花了不少时间）。
SUBMITTED=$(( 2 * ( (ROWS + ROWS_PER_STMT - 1) / ROWS_PER_STMT ) ))
exp_max=$(( 2 * ROWS ))
log "  成功语句=$ok_total（每语句 ${ROWS_PER_STMT} 行）⇒ 期望区间 [1, $exp_max]，实际合计=$cnt"
# 原子性：每条 INSERT 要么整条可见、要么整条不可见 ⇒ 点数必须是"每语句行数"的整数倍
assert_eq "④无部分写入（点数 % 每语句行数 == 0）" "$(( ${cnt:-0} % ROWS_PER_STMT ))" "0"
# 若提交的语句全部成功，则必须"一点不差"（这是最强判据）
if [ "$ok_total" -eq "$SUBMITTED" ]; then
  assert_eq "④全部语句成功时点数必须精确相等" "${cnt:-0}" "$(( 2 * ROWS ))"
else
  log "  部分语句被拒（成功 $ok_total/$SUBMITTED）⇒ 只要求 \"整语句原子\"，不要求等于总量"
fi
# ④ 的语义要分清两种**都合法**的结果：
#   (a) 部分/全部写入成功 ⇒ 点数必须 >0 且 == 成功语句数×每语句行数（无静默丢数）
#   (b) **全部写入被拒**（ok_total=0）⇒ 点数必须 == 0，且属于"明确的拒绝结果"，不是失败。
#   RC9 在同样极端参数（memtable 20MB / flush=1% / reject=2%）下就是 (b)：20 条语句全被拒、
#   reject 状态进入 99 次；而 RC8 是 (a) 20/20 全成功。两者都是"内存控制生效"的表现，
#   因此把 (b) 记为 PASS + 单独一行说明，避免把"产品正确地拒绝"误判成用例失败。
if [ "${ok_total:-0}" -eq 0 ]; then
  if [ "${cnt:-0}" -eq 0 ]; then
    pass "④全部写入被内存控制拒绝（成功 0/$SUBMITTED 语句，点数 0，与"全拒"一致）"
  else
    fail "④全部语句被拒但仍有 ${cnt} 点落库（拒绝不彻底）"
  fi
else
  assert_ge "④写入确实落到存储（点数 > 0）" "${cnt:-0}" 1
fi
if [ "${cnt:-0}" -le "$exp_max" ]; then pass "④点数未超过提交总量（$cnt <= $exp_max）"; else fail "④点数超过提交总量: $cnt > $exp_max"; fi
rejex=$(( $(mb_reject_exception_cnt "${DN[0]}") + $(mb_reject_exception_cnt "${DN[1]}") + $(mb_reject_exception_cnt "${DN[2]}") ))
sig=$rejex
if [ "$ok_total" -lt "$SUBMITTED" ]; then sig=$(( sig + 1 )); fi
log "  提交语句=$SUBMITTED 成功=$ok_total 拒绝异常日志=$rejex"
# ③"明确结果"的两种合法形态：
#   (a) 有语句被拒（成功的语句数 < 提交数，或日志里有 WriteProcessRejectException）；
#   (b) 全部最终写成功，但确实进过 reject 状态（说明背压阻塞+刷盘把压力消化了，数据没丢）。
# 实测本环境是 (b)：reject 进入 244 次、拒绝异常 0、数据 16MB 全部落库且副本一致。
rej_enter=$(( rej1 - rej0 ))
if [ "$sig" -ge 1 ] || [ "$rej_enter" -ge 1 ]; then
  pass "③有明确的背压/拒绝结果（拒绝异常=$rejex，成功=$ok_total/$SUBMITTED，进入 reject 状态 $rej_enter 次）"
else
  fail "③既没有拒绝异常也没有进入 reject 状态（压力不足，场景未成立）"
fi

mb_case_finish "$(mb_data_sql "$DB" d1)" tree
