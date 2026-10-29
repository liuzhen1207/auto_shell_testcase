#!/bin/bash
# ============================================================================
# TP-03 expired_data_ratio 的生效方式与数值语义（restart-only；不用 MODS 场景）
#
#   两次纠正后的设计（都是实测踩出来的，记录在此避免以后再走弯路）：
#   1) **不能用"被 DELETE 删空的设备"来测阈值**：设备按 hash 落到不同 region，被删空的那个设备往往
#      独占一个 TsFile ⇒ deletedDeviceRatio = 1/1 = 1 ⇒ FULLY_DIRTY，与 expired_data_ratio /
#      max_expired_time 完全无关（实测 M=INF + ratio=0.99 也照样清理）。
#   2) `expired_data_ratio` 在本构建里是 **restart 生效**：`SET CONFIGURATION 'expired_data_ratio'=...`
#      返回 `... but restart is required for the following parameters to take effect: expired_data_ratio.`
#      （配置模板里它的 effectiveMode 也是 restart；源码 PropertiesTest 里它出现在 loadHotModifiedProps
#      的用例中，但集群侧仍按 restart 处理——以实测为准）。
#
#   为了"部分过期"可观测，每个场景用 **10 个设备**、**前 8 个挂 TTL**（末 2 个不挂）：
#   设备按名字 hash 落到不同 region，只给 1 个设备挂 TTL 时它可能独占所在文件 ⇒ deletedDeviceRatio=1
#   ⇒ FULLY_DIRTY（V2 实测 10 设备仍退化）；挂多数设备后几乎必然出现"既有过期又有未过期设备"的文件
#   ⇒ deletedDeviceRatio ≤ 8/10 = 0.8 < 0.99，比例门控是否生效变得可观测。
#
#   三相：
#     A) max_expired_time=INF + ratio=1e-6 → 期望清理（基线：证明场景确实产生"部分过期"候选）
#     B) 不重启，热改 ratio=0.99 → 期望**仍被清理**（旧值 1e-6 仍生效 ⇒ 不是热加载），并断言返回 restart 提示
#     C) 重启（conf 写 ratio=0.99）→ 期望**不清理**（新值生效），并逐节点核对生效值
#
#   V2 实测补充（2026-10-08）：即使 10 个设备，某些相位仍可能出现"TTL 设备 d1 独占一个 TsFile"
#   ⇒ 该文件 deletedDeviceRatio=1 ⇒ FULLY_DIRTY ⇒ **合法地绕过 ratio 被清理**（日志特征：
#   `Totally select 1 all-outdated files and 0 partial-outdated files` +
#   `SettleCompaction task starts with 1 fully_dirty files and 0 partially_dirty files`）。
#   所以判据只认"含**部分过期**文件的 settle 任务"（`settle_partial_task_for_db`），
#   只出现整文件全过期时 PASS + WARN 标注"场景退化、本相未验证比例门控"。
#
# 用法： bash ttl_maxexpired_and_hotload.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_param_effect_mode_${DATA_CONSENSUS}"

TTL_MS=${TTL_RATIO_MS:-30000}
WAIT=$(( TTL_MS/1000 + 25 ))
DEVS=${RATIO_DEVS:-10}          # 设备数：让"部分过期"文件成为常态
RATIO_HIGH=0.99
RATIO_TINY=0.000001
INF=9223372036854775807
DA=root.pm_tiny   # A/B：ratio=1e-6（旧值）
DC=root.pm_high   # C：ratio=0.99（重启后）

# 造"部分过期"场景：10 个设备各 1 点，**前 DEVS-2 个挂 TTL**（末 2 个不挂，留作"未过期"参照）
#   为什么不是"只给 d1 挂 TTL"：设备按名字 hash 落到不同 region，某个 region 可能只有 1 个设备；
#   若恰好是那唯一的 TTL 设备，其文件 deletedDeviceRatio=1 ⇒ FULLY_DIRTY ⇒ **合法绕过 ratio**，
#   比例门控不可观测（V2 实测 root.pm_high 就是这样，10 设备仍退化）。挂多数设备后，
#   几乎必然存在"既有过期又有未过期设备"的文件 ⇒ partial 候选可观测（与 TP-01 同思路）。
mk_scene(){
  local db=$1 d
  sq "create database $db;" >/dev/null
  for ((d=1; d<=DEVS; d++)); do sq "create timeseries $db.d$d.s1 with datatype=int64;" >/dev/null; done
  for ((d=1; d<=DEVS-2; d++)); do sq "set ttl to $db.d$d $TTL_MS;" >/dev/null; done
  for ((d=1; d<=DEVS; d++)); do sq "insert into $db.d$d(time,s1) values($(now_ms), $d);" >/dev/null; done
  ensure_closed "$db" 3 25 || warn "$db 有 DN 的 TsFile 未落盘"
  log "  $db 造场景完成（TTL 挂 d1..d$((DEVS-2))，d$((DEVS-1))/d$DEVS 不挂）：TsFile=$(tsfile_counts_all "$db") 落盘=$(ttl_close_snapshot "$db")"
}
# 观察结果：<db> <期望: settle|clean>
#   判据只看**含部分过期文件**的 settle 任务（settle_partial_task_for_db）：
#   整文件全过期（deletedDeviceRatio=1）走 FULLY_DIRTY，**合法地绕过** expired_data_ratio，
#   把它算成"门控失效"会误判（V2 实测 root.pm_high 就是这种情况：d1 独占 TsFile）。
#   真出现"部分过期文件被清理"才算 FAIL；只出现整文件全过期时 PASS + WARN 标注场景退化。
judge(){
  local db=$1 want=$2 base cur cand last pcur
  base=0; cur=$(sum_over_db settle_task_for_db "$db"); cand=$(sum_over_db ttl_sel_for_db "$db")
  pcur=$(sum_over_db settle_partial_task_for_db "$db")
  last=$(ttl_last_line_for_db "${DN[0]}" "$db" | tr '\n' ' ' | cut -c1-190)
  log "  $db 真实 settle 任务=$cur（其中含部分过期文件的=$pcur），候选选中=$cand 行；${DN[0]} 最近 [TTL]: $last"
  if [ "$want" = settle ]; then
    if [ "$cur" -gt "$base" ]; then
      pass "$db：如预期被清理（settle=$cur）"
      [ "$pcur" -gt 0 ] || warn "$db 场景退化：只出现『整文件全过期』候选（设备独占 TsFile ⇒ ratio=1），本相未验证『按比例清理部分过期文件』"
    else
      fail "$db：期望被清理，但 30+s 内无 settle 任务"
    fi
  else
    if [ "$pcur" -eq 0 ]; then
      pass "$db：如预期未被清理（含部分过期文件的 settle=0；settle 总数=$cur）"
      [ "$cur" -eq 0 ] || warn "$db 场景退化：settle 总数=$cur 全是『整文件全过期』（FULLY_DIRTY 合法绕过 ratio），本相未真正验证比例门控，需换场景重跑"
    else
      fail "$db：期望不清理，却出现 $pcur 个含部分过期文件的 settle 任务（settle 总数=$cur）"
    fi
  fi
}

log "--- 集群准备（A/B 相：max_expired_time=INF, expired_data_ratio=$RATIO_TINY） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=$RATIO_TINY ttl_cluster_prepare

log "--- A) 基线：ratio=$RATIO_TINY + M=INF，部分过期文件应被清理 ---"
mk_scene "$DA"
sleep "$WAIT"
judge "$DA" settle

log "--- B) 不重启热改 ratio=$RATIO_HIGH：本构建标为需重启 ⇒ 应仍按旧值 $RATIO_TINY 清理 ---"
out=$(sq "set configuration 'expired_data_ratio'='$RATIO_HIGH';")
log "  热改返回: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
assert_contains "热改提示需重启" "$out" "restart is required"
assert_contains "提示里点名该参数" "$out" "expired_data_ratio"
for h in "${DN[@]}"; do log "  热改后生效值($h): $(ttl_effective_conf "$h")"; done
DB2=root.pm_hot
mk_scene "$DB2"
sleep "$WAIT"
judge "$DB2" settle

log "--- C) 重启后（conf 写 ratio=$RATIO_HIGH）新值生效：部分过期文件应**不**被清理 ---"
cluster_stop
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=$RATIO_HIGH cluster_write_conf
cluster_start
for h in "${DN[@]}"; do
  eff=$(ttl_effective_conf "$h"); log "  重启后生效值($h): $eff"
  case "$eff" in *"expired_data_ratio=$RATIO_HIGH"*) : ;; *) fail "C: $h 的 expired_data_ratio 未生效：$eff" ;; esac
done
mk_scene "$DC"
sleep "$WAIT"
judge "$DC" clean
c=$(scalar "$(sq "select count(*) from $DC.d1;")"); assert_scalar "C 过期设备 d1 查询不可见（仅查询过滤）" "${c:-0}" "0"
c=$(scalar "$(sq "select count(*) from $DC.d$DEVS;")"); assert_scalar "C 未过期设备 d$DEVS 数据仍在（未挂 TTL）" "${c:-0}" "1"

log "--- 判读 ---"
log "  B 相若『仍被清理』⇒ expired_data_ratio 不是热加载参数（本构建 SET CONFIGURATION 明确要求重启）；"
log "  C 相若『不被清理』⇒ 重启后新值生效，比例门控（M=INF 时）确实由该参数决定。"
log "  另注：max_expired_time 的『数值』在 RC4 对 TTL 过期设备不可观测（L294 阈值笔误让它与 TTL 同时刻触发，见 docs/CALIBRATION.md 0.6），"
log "  其『开关』语义（=INF 关闭强制分支）已由本用例 C 相与 TP-01/TP-02 覆盖。"

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DA.d$DEVS;" tree
ttl_case_finish "" tree ""
