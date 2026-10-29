#!/bin/bash
# ============================================================================
# TP-04 缺陷门禁（TDB-610）：同一个 DataRegion 被注册两次到压缩/TTL 调度列表
#   ⇒ 该 region 在每个 ttl_check_interval 被检查两遍（同一线程、相差约 1ms 的两条 Start ttl）
#
#   判据：目标库的 `Start ttl` 行数 ÷ 不同秒数（按 region 取最大）= 1.00 为正常；
#         ≥1.5（实测 2.00）即命中缺陷。
#   对照组：同一次运行里另一个库**不动它的时间索引缓存**，应保持 1.00 —— 说明测量方法本身没问题。
#
#   触发条件（源码级，实测稳定）：某 region 启动时若"没有异步恢复任务"
#   （`asyncTsFileResourceRecoverTaskList` 为"非 null 但空"），构造函数与
#   `StorageEngine.asyncRecoverTsFileResource()` 会各注册一次；把该 region 的
#   `system/databases/<db>/<regionId>/FileTimeIndexCache_0` 挪走即可稳定构造
#   （该文件只是时间索引缓存，缺失时按同步路径恢复，不影响数据；用例结束会还原）。
#
#   可选深度校验：若节点上部署了只读探查 agent（/tmp/ttl_dupcheck/insp.jar），
#   直接 dump `CompactionScheduleTaskManager.dataRegionList` 作为**佐证**：
#   与比值一致时只记 PASS/日志，不一致（比值正常但列表有重复）才算 FAIL。
#
# 用法： bash ttl_dup_region_register.sh [--consensus ...] [--framework 0|1]
# 参数： REG_DEVS=12  REG_TTL_MS=60000  REG_WIN_SEC=60
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_dup_region_register_${DATA_CONSENSUS}"

DB_CTL=root.regdup_ctl      # 对照组（缓存不动）
DB_TGT=root.regdup_tgt      # 目标组（启动前挪走 FileTimeIndexCache_0）
DEVS=${REG_DEVS:-12}
TTL_MS=${REG_TTL_MS:-60000}
WIN=${REG_WIN_SEC:-60}
INF=9223372036854775807

mk_db(){ local db=$1 d
  sq "create database $db;" >/dev/null
  for ((d=1; d<=DEVS; d++)); do sq "create timeseries $db.d$d.s1 with datatype=int64;" >/dev/null; done
  for ((d=1; d<=DEVS-2; d++)); do sq "set ttl to $db.d$d $TTL_MS;" >/dev/null; done
  for ((d=1; d<=DEVS; d++)); do sq "insert into $db.d$d(time,s1) values($(now_ms), $d);" >/dev/null; done
  ensure_closed "$db" 3 25 || warn "$db 有 DN 的 TsFile 未落盘"
  log "  $db 场景就绪：region=[$(ttl_region_ids "${DN[0]}" "$db" | tr '\n' ' ')] TsFile=$(tsfile_counts_all "$db")"
}

# 逐节点测"每 region 行数/秒数/比值"，把本轮的最大比值写入全局 MEASURE_MAX
# 注意：**不能用 echo 返回**——log() 也会写 stdout，命令替换会把日志文本一起捕获（实测踩到）
MEASURE_MAX=0.00
measure_max(){ local db=$1 h raw mx all=0.00
  for h in "${DN[@]}"; do
    raw=$(ttl_check_ratio "$h" "$db" "$WIN")
    mx=$(ttl_check_ratio_max "$raw")
    log "  $db@$h（region 行数 秒数 比值）：$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-220)"
    all=$(awk -v a="$all" -v b="$mx" 'BEGIN { printf "%.2f", (b + 0 > a + 0) ? b : a }')
  done
  MEASURE_MAX=$all
}

# 可选的列表级佐证（直接观测调度列表）：AGENT_RC = 0 无重复 / 2 发现重复 / 1 不可用
# 每一步都打日志，便于回答"这次为什么没做列表级校验"
AGENT_RC=1
agent_dump_check(){ local h=$1 pid out jar=/tmp/ttl_dupcheck/insp.jar atlog=/tmp/agent_attach_case.log
  AGENT_RC=1
  if ! sshx "$h" "[ -f $jar ]" 2>/dev/null; then
    log "  （$h 上没有 $jar，跳过列表级校验）"
    return 1
  fi
  pid=$(sshx "$h" "pgrep -f 'com.timecho.iotdb.DataNode' | head -1" 2>/dev/null | tr -d '\r')
  if [ -z "$pid" ]; then
    log "  （$h 上找不到 DataNode 进程，跳过列表级校验）"
    return 1
  fi
  sshx "$h" "cd /tmp/ttl_dupcheck && java -cp /tmp/ttl_dupcheck Attacher $pid $jar /tmp/ttl_dupcheck/insp_case.out" >"$atlog" 2>&1 || true
  out=$(sshx "$h" "cat /tmp/ttl_dupcheck/insp_case.out 2>/dev/null" 2>/dev/null)
  log "  agent($h, pid=$pid) 关键行：$(printf '%s' "$out" | grep -E '^size = |同一 region 注册了多次|是\*\*同一个对象\*\*' | tr '\n' ' ' | cut -c1-200)"
  if printf '%s' "$out" | grep -qE '同一 region 注册了多次|是\*\*同一个对象\*\*'; then AGENT_RC=2; return 2; fi
  if printf '%s' "$out" | grep -qE 'dataRegionList'; then AGENT_RC=0; return 0; fi
  log "  （agent dump 不可解析；attach 输出：$(tail -2 "$atlog" 2>/dev/null | tr '\n' ' ' | cut -c1-160)）"
  return 1
}

log "--- 集群准备（ttl_check_interval=$TTL_CHECK_INTERVAL_MS, max_expired_time=INF, expired_data_ratio=$EXPIRED_DATA_RATIO） ---"
MAX_EXPIRED_TIME_MS=$INF EXPIRED_DATA_RATIO=0.000001 ttl_cluster_prepare

log "--- 造场景：$DB_CTL（对照）与 $DB_TGT（目标，稍后挪走时间索引缓存） ---"
mk_db "$DB_CTL"
mk_db "$DB_TGT"

log "--- 停集群，只挪走 $DB_TGT 的时间索引缓存（制造「启动时同步恢复」）---"
cluster_stop
for h in "${DN[@]}"; do
  n=$(ttl_drop_time_index_cache "$h" "$DB_TGT")
  c=$(sshx "$h" "ls -1 $DB_DIR/data/datanode/system/databases/$DB_CTL/*/FileTimeIndexCache_0 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  log "  $h：$DB_TGT 挪走 $n 个缓存文件；$DB_CTL 保留 $c 个（对照）"
done
cluster_start
sleep 25    # 等 TTL 调度线程跑起来（启动后第一个周期不一定落在这个窗口里）

log "--- 测量窗口 ${WIN}s：每个 region 的 Start ttl 行数 ÷ 不同秒数 ---"
measure_max "$DB_TGT"; mx_tgt=$MEASURE_MAX
measure_max "$DB_CTL"; mx_ctl=$MEASURE_MAX
log "  最大比值：$DB_TGT=$mx_tgt，$DB_CTL=$mx_ctl"

log "--- 可选佐证：直接 dump 调度列表（需要只读 agent） ---"
agent_dump_check "${DN[0]}" || true

log "--- 判定（TDB-610 门禁） ---"
dup=0
if [ "$(awk -v v="$mx_tgt" 'BEGIN{print (v+0==0)?1:0}')" = "1" ]; then
  fail "$DB_TGT 在 ${WIN}s 窗口内没有任何 TTL 检查日志 ⇒ 场景无效，无法判定（检查该库是否仍有 TTL 规则/数据）"
elif [ "$(awk -v v="$mx_tgt" 'BEGIN{print (v+0>=1.5)?1:0}')" = "1" ]; then
  dup=1
  fail "命中 TDB-610：$DB_TGT 的 region 每周期被检查 $mx_tgt 次（正常 1.00）——同一 DataRegion 在调度列表里注册了两次"
else
  pass "TDB-610 未复现：$DB_TGT 每周期检查次数=$mx_tgt（正常 1.00）"
fi
if [ "$(awk -v v="$mx_ctl" 'BEGIN{print (v+0>=1.5)?1:0}')" = "1" ]; then
  fail "对照组 $DB_CTL 也出现 $mx_ctl（测量方法可疑，需排查）"
else
  pass "对照组 $DB_CTL 每周期检查次数=$mx_ctl（测量方法可信）"
fi
case "$AGENT_RC" in
  2) if [ "$dup" = "1" ]; then pass "agent 佐证与比值一致：dataRegionList 里确有重复元素"
     else fail "agent 直接观测到 dataRegionList 有重复元素，但比值正常（测量窗口可能太短）"; fi ;;
  0) if [ "$dup" = "1" ]; then fail "比值显示重复、agent 却未观测到重复（两者矛盾，需人工确认）"
     else pass "agent 佐证与比值一致：dataRegionList 无重复元素"; fi ;;
  *) warn "未做列表级校验（agent 未部署/DataNode 未运行），判据仅依据每周期行数÷秒数比值" ;;
esac

log "--- 还原时间索引缓存 ---"
for h in "${DN[@]}"; do
  n=$(ttl_restore_time_index_cache "$h" "$DB_TGT")
  log "  $h 还原 $n 个（$DB_TGT）"
done

log "--- 收尾三件套 ---"
post_checks "select count(*) from $DB_TGT.d$DEVS;" tree
ttl_case_finish "" tree ""
