#!/bin/bash
# ============================================================================
# TP-01 TTL 参数值生效 / 热加载 / 重启生效 验证
#   Part A: ttl_check_interval
#           A1 实测检查周期 ≈ 配置值（按该库的 [TTL] 日志行推算）
#           A2 SET CONFIGURATION 改值：断言返回 "restart is required ..."
#           A3 重启后新值生效（再测周期 ≈ 新值）
#   Part B: 热加载开关门控 TTL 物理清理（enable_seq/unseq_space_compaction）
#           关闭 → 无 settle 选中（查询仍过滤过期数据）；打开 → 清理恢复
#   Part C: expired_data_ratio 阈值语义（改值需重启）
#           C1) max_expired_time=1h       + ratio=0.99 → 期望不清理（文档语义）
#           C2) max_expired_time=Long.MAX + ratio=0.99 → 期望不清理（关闭"过期太久"强制规则后只看比例）
#           C3) max_expired_time=Long.MAX + ratio=0.0  → 期望清理（证明清理链路正常）
#           判读：C1 出 settle 而 C2 不出 ⇒ 强制清理阈值笔误导致比例门控被短路（详见 Part C 注释）
#   收尾：sync lag 归零 / 副本一致性 / CN-DN 日志
# 用法： bash ttl_param_effect.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_param_effect_${DATA_CONSENSUS}"

DB=root.param_p
DBR=root.param_r
TTL_MS=${TTL_CASE_MS:-15000}
WAIT=$(( TTL_MS/1000 + 20 ))
NEW_INTERVAL_MS=${NEW_INTERVAL_MS:-15000}

log "--- 集群准备（conf: ttl_check_interval=$TTL_CHECK_INTERVAL_MS ms, expired_data_ratio=$EXPIRED_DATA_RATIO, max_expired_time=$MAX_EXPIRED_TIME_MS） ---"
ttl_cluster_prepare

# SKIP_AB=1 时只跑 Part C（调试/复跑参数相时省 5 分钟）
if [ "${SKIP_AB:-0}" != "1" ]; then

log "--- 建库建序列、挂一条大 TTL 规则并写 1 个点 ---"
log "    （DN 只对"有数据且挂了 TTL"的区域打 [TTL] 检查日志，所以测周期前必须先有数据）"
sq "create database $DB;" >/dev/null
sq "create timeseries $DB.d1.s1 with datatype=int64;" >/dev/null
sq "set ttl to $DB 300000;" >/dev/null
sq "insert into $DB.d1(time,s1) values($(now_ms), 1);" >/dev/null
sq "flush;" >/dev/null
sleep 12   # 让 DataRegion 至少完成两轮检查

# ---------------------------------------------------------------------------
log "--- Part A1) ttl_check_interval 实际生效 ---"
iv1=$(measure_ttl_interval "${DN[0]}" "$DB" 30)
log "  实测检查周期 = ${iv1}s（配置 $((TTL_CHECK_INTERVAL_MS/1000))s）"
log "  该库最近 [TTL] 日志: $(ttl_last_line_for_db "${DN[0]}" "$DB" | tr '\n' ' ' | cut -c1-200)"
awk -v a="$iv1" -v b="$TTL_CHECK_INTERVAL_MS" 'BEGIN{exit !(a>0 && a < b/1000 + 6 && a > b/1000 - 3)}' \
  && pass "ttl_check_interval 生效：实测 ${iv1}s ≈ 配置 $((TTL_CHECK_INTERVAL_MS/1000))s" \
  || fail "ttl_check_interval 未生效：实测 ${iv1}s，配置 $((TTL_CHECK_INTERVAL_MS/1000))s"

log "--- Part A2) SET CONFIGURATION 热改（源码标注需重启）：期望返回 restart is required ---"
hot=$(sq "set configuration 'ttl_check_interval'='$NEW_INTERVAL_MS';")
log "  返回: $(printf '%s' "$hot" | tr '\n' ' ' | cut -c1-220)"
assert_contains "热改提示需重启" "$hot" "restart is required"
assert_contains "热改不改动运行中的周期（提示里点名该参数）" "$hot" "ttl_check_interval"

log "--- Part A3) 重启后新值生效（实测周期 ≈ $((NEW_INTERVAL_MS/1000))s） ---"
TTL_CHECK_INTERVAL_MS=$NEW_INTERVAL_MS
cluster_stop
TTL_CHECK_INTERVAL_MS=$NEW_INTERVAL_MS cluster_write_conf
cluster_start
iv2=$(measure_ttl_interval "${DN[0]}" "$DB" 40)
log "  重启后实测检查周期 = ${iv2}s（新配置 $((NEW_INTERVAL_MS/1000))s）"
awk -v a="$iv2" -v b="$NEW_INTERVAL_MS" 'BEGIN{exit !(a>0 && a < b/1000 + 12 && a > b/1000 - 5)}' \
  && pass "重启后新值生效：实测 ${iv2}s ≈ 新配置 $((NEW_INTERVAL_MS/1000))s" \
  || fail "重启后新值未生效：实测 ${iv2}s，新配置 $((NEW_INTERVAL_MS/1000))s"

# ---------------------------------------------------------------------------
log "--- Part B) 热加载开关门控 TTL 物理清理 ---"
sq "set ttl to $DB $TTL_MS;" >/dev/null      # 覆盖成小 TTL，让数据能过期
T1=$(now_ms)
sq "insert into $DB.d1(time,s1) values($T1, 1);" >/dev/null
sq "flush;" >/dev/null
files1=$(tsfile_counts_all "$DB")
log "  写入并 flush：tsFiles=$files1"
log "  关闭 seq/unseq compaction（热加载）："
for k in 'enable_seq_space_compaction' 'enable_unseq_space_compaction'; do
  log "    SET $k=false -> $(sq "set configuration '$k'='false';" | head -1)"
done
base_sel=$(sum_over "ttl_sel_for_db" "$DB" 2>/dev/null || true)
base_sel=0; for h in "${DN[@]}"; do base_sel=$((base_sel + $(ttl_sel_for_db "$h" "$DB"))); done
log "  等 ${WAIT}s 让数据过期（查询应已过滤，但不应有物理清理）..."
sleep "$WAIT"
c=$(scalar "$(sq "select count(*) from $DB.d1;")"); c=${c:-0}
assert_scalar "关闭 compaction 时过期数据仍被查询过滤" "$c" "0"
sleep 25
now_sel=0; for h in "${DN[@]}"; do now_sel=$((now_sel + $(ttl_sel_for_db "$h" "$DB"))); done
now_files=$(tsfile_counts_all "$DB")
[ "$now_sel" -le "$base_sel" ] && pass "关闭 compaction 后 $DB 无 settle 选中（物理清理被门控）：$base_sel -> $now_sel，tsFiles=$now_files" \
                               || fail "关闭 compaction 后 $DB 仍发生选中：$base_sel -> $now_sel"

log "  恢复 seq/unseq compaction=true（热加载）："
for k in 'enable_seq_space_compaction' 'enable_unseq_space_compaction'; do
  log "    SET $k=true -> $(sq "set configuration '$k'='true';" | head -1)"
done
deadline=$(( $(date +%s) + CLEANUP_WAIT_SEC )); recovered=0
while (( $(date +%s) < deadline )); do
  cur=0; for h in "${DN[@]}"; do cur=$((cur + $(ttl_sel_for_db "$h" "$DB"))); done
  log "  等恢复清理: $DB selectedAllOutdated=$cur(+$((cur-now_sel))) tsFiles=$(tsfile_counts_all "$DB")"
  [ "$cur" -gt "$now_sel" ] && { recovered=1; break; }
  sleep 5
done
[ "$recovered" = "1" ] && pass "重新打开 compaction 后 TTL 清理恢复（热加载生效）" || fail "重新打开 compaction 后 ${CLEANUP_WAIT_SEC}s 内未恢复清理"

fi   # SKIP_AB

# ---------------------------------------------------------------------------
# Part C：expired_data_ratio 门控 与 "过期太久"强制清理 的关系
#
# 源码（RC4 iotdb-core/datanode/.../compaction/selector/impl/SettleSelectorImpl.java
#       selectFileBaseOnDirtyData() L276-L318）：
#   if (hasSetTTL) {
#     if (!isDeleted) return NOT_SATISFIED;                       // 还有带 TTL 的设备没过期 → 整个文件不选
#     if (currentTime > endTime) {
#       outdatedTimeDiff = currentTime - endTime;                 // 从设备末端数据时间算
#       ttlThreshold = 3 * ttl > ttl ? ttl : Long.MAX_VALUE;      // ← 本意是 3*ttl（防溢出），实测写成 ttl
#       hasExpiredTooLong |= outdatedTimeDiff > Math.min(max_expired_time, ttlThreshold);
#     }
#   }
#   hasExpiredTooLong = (max_expired_time != Long.MAX_VALUE) && hasExpiredTooLong;
#   if (hasExpiredTooLong || deletedDeviceRatio >= expired_data_ratio) → PARTIALLY_DIRTY
#
# 而 isDeviceAlive(device, ttl) ⟺ endTime >= now - ttl，即"设备被判过期(isDeleted)"本身就等价于
# now - endTime > ttl；又 min(max_expired_time, ttl) <= ttl，于是：
#   max_expired_time != Long.MAX_VALUE（默认 1 个月）时 hasExpiredTooLong 恒为真
#   ⇒ expired_data_ratio 被短路：文件里只要有一个 TTL 设备过期，下一次检查就会被 settle。
#   只有 max_expired_time = Long.MAX_VALUE 时才只剩比例门控（与配置模板文档一致）。
#
# 因此 Part C 做三相隔离（C1 是按文档/修复前代码的断言，C2/C3 用于定位机制）：
#   C1) max_expired_time=1h        + ratio=0.99 → 期望不清理（当前实现会 FAIL = 缺陷复现）
#   C2) max_expired_time=Long.MAX  + ratio=0.99 → 期望不清理（关闭强制规则后比例门控应生效）
#   C3) max_expired_time=Long.MAX  + ratio=0.0  → 期望清理（证明清理链路本身正常）
# ---------------------------------------------------------------------------
TTL_RATIO=${TTL_RATIO_MS:-120000}
WAIT_RATIO=$(( TTL_RATIO/1000 + 40 ))
RATIO_DEVS=${RATIO_DEVS:-12}      # 设备数：保证 d1 所在的 TsFile 里还有别的设备 ⇒ 过期占比 ≤1/12 可观测
sum_over_db(){ local f=$1 db=$2 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h" "$db"))); done; echo "${s:-0}"; }

# 单相：<名> <ratio> <max_expired_time> <期望是否清理 0|1>
ratio_phase(){
  local name=$1 ratio=$2 maxexp=$3 expect=$4
  local db="root.param_$name" h d t snap base cur
  log "--- Part C/$name) expired_data_ratio=$ratio + max_expired_time=$maxexp（期望：$([ "$expect" = 1 ] && echo '清理' || echo '不清理')）---"
  cluster_stop
  EXPIRED_DATA_RATIO="$ratio" MAX_EXPIRED_TIME_MS="$maxexp" cluster_write_conf
  cluster_start
  # 逐节点核对"真正生效"的参数值（table 方言 show configuration）；写文件成功 != 生效，必须核对
  for h in "${DN[@]}"; do
    local eff; eff=$(ttl_effective_conf "$h")
    log "  生效配置($h): ${eff:-<读取失败>}"
    case "$eff" in *"expired_data_ratio=$ratio"*) : ;; *) fail "$name: $h 的 expired_data_ratio 未生效（期望 $ratio）：${eff:-读取失败}" ;; esac
    case "$eff" in *"max_expired_time=$maxexp"*)  : ;; *) fail "$name: $h 的 max_expired_time 未生效（期望 $maxexp）：${eff:-读取失败}" ;; esac
  done
  sq "create database $db;" >/dev/null
  # 多设备场景，且 **TTL 挂在多数设备上**（最后 2 个不挂）：
  #   - 只挂 1 个设备时，该设备常常独占一个 TsFile ⇒ deletedDeviceRatio=1 ⇒ FULLY_DIRTY，
  #     比例门控根本没参与判定（V2 上实测踩到）；
  #   - 挂多数设备后，几乎必然存在"既有过期设备又有未过期设备"的混合文件 ⇒ partial 候选可观测。
  for ((d=1; d<=RATIO_DEVS; d++)); do sq "create timeseries $db.d$d.s1 with datatype=int64;" >/dev/null; done
  for ((d=1; d<=RATIO_DEVS-2; d++)); do sq "set ttl to $db.d$d $TTL_RATIO;" >/dev/null; done
  t=$(now_ms)
  for ((d=1; d<=RATIO_DEVS; d++)); do sq "insert into $db.d$d(time,s1) values($t, $d);" >/dev/null; done
  ensure_closed "$db" 3 25 || warn "$name: 有 DN 的 TsFile 未落盘（该副本不参与 settle 选择）"
  log "  $name 各 DN 落盘(Async close)条数: $(ttl_close_snapshot "$db")"
  base=$(sum_over_db settle_task_for_db "$db")
  log "  写入 T=$t（TTL=$((TTL_RATIO/1000))s，设备数=$RATIO_DEVS，前 $((RATIO_DEVS-2)) 个挂 TTL）；基线 settle=$base；等待 ${WAIT_RATIO}s"
  sleep "$WAIT_RATIO"
  cur=$(sum_over_db settle_task_for_db "$db")
  pcand=$(sum_over_db ttl_partial_sel_cnt "$db")     # ← 判据：partial 候选数（比例门控是否参与判定）
  acand=$(sum_over_db ttl_all_outdated_sel_cnt "$db")
  log "  $name 真实 settle 任务: $base -> $cur；partial 候选=$pcand 行，all-outdated 候选=$acand 行"
  for h in "${DN[@]}"; do
    log "  $name $h [TTL] 记录: $(ttl_last_line_for_db "$h" "$db" | tr '\n' ' ' | cut -c1-190)"
  done
  if [ "$expect" = 1 ]; then
    if [ "$pcand" -gt 0 ]; then
      pass "$name：预期清理，出现 partial 候选（$pcand 行）且 settle=$cur"
    elif [ "$cur" -gt "$base" ]; then
      pass "$name：预期清理，settle=$cur（该库文件都是整文件全过期，属合法清理）"
    else
      fail "$name：预期清理，但 ${WAIT_RATIO}s 内既无 partial 候选也无 settle 任务"
    fi
  else
    if [ "$pcand" -eq 0 ]; then
      pass "$name：比例门控生效——没有 partial 候选（settle=$cur；all-outdated 候选=$acand 属合法整文件清理）"
      # 只有 all-outdated 候选时，本相"没被清理"的解释可能是"文件全是整文件全过期、已合法清掉"，
      # 而不是"部分过期文件被比例门控拦住" ⇒ 标注场景退化，避免把退化当门控证据（V2 实测踩到）
      [ "$acand" -eq 0 ] || warn "$name 场景退化：出现过 'all-outdated 候选'（$acand 行，TTL 设备独占 TsFile ⇒ ratio=1），本相未直接验证比例门控对『部分过期文件』的拦截"
    else
      fail "$name：ratio=$ratio 下仍出现 $pcand 行 partial 候选并生成 settle 任务（$base -> $cur）"
    fi
  fi
}

ratio_phase r1 0.99 3600000             0   # C1 期望不清理（缺陷复现点）
ratio_phase r2 0.99 9223372036854775807 0   # C2 关闭强制规则 → 只看比例
ratio_phase r3 0.0  9223372036854775807 1   # C3 比例 0.0 → 应清理

log "--- Part C 判读 ---"
log "  若 C1 出现 settle、C2 不出现、C3 正常 ⇒ 选择由\"过期太久\"强制分支决定，"
log "  即 L294 ttlThreshold 本意 3*ttl 却写成 ttl，导致 min(max_expired_time, ttl) 恒被过期条件满足，"
log "  expired_data_ratio 被短路（缺陷，非用例语义问题；max_expired_time=Long.MAX_VALUE 时比例才生效）。"

log "--- 收尾三件套 ---"
# 用最后一相里"无 TTL、永不清理"的 d2 做副本一致性基准，避免清理竞态干扰
post_checks "select count(*) from root.param_r3.d2;" tree
ttl_case_finish "" tree ""
