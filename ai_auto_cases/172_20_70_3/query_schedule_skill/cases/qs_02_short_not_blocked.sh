#!/bin/bash
# QS-02 核心验收：单查询线程下，长查询进行中短查询仍能快速返回
#   覆盖需求：REQ-01（短查询不被长查询阻塞）、REQ-02（长查询不饿死）
#
#   场景（源自需求分析 §3.1 / 软件测试文档「改进测试方式」）：
#     query_thread_count=1 → 只有一个 Worker 线程
#     后台跑一个"全量扫描"长查询
#     同时持续打"随机序列最新值"短查询
#   判据：
#     ① 短查询 P99 < 50ms（需求硬指标）
#     ② 短查询有成功的操作（okOperation > 0）
#     ③ 长查询最终正常结束（rc=0），未被饿死
set -o pipefail   # 不用 -u：common.sh 里部分可选变量未定义
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-02

# 需求指定的测试口径
# query_timeout_threshold 必须**明显大于**长查询时长：实测设 600s 时，
# 1101s 的全量查询会被 Sentinel 中止（rc=1），看起来像"REQ-02 未达成"，
# 实际是超时机制（REQ-06）在正常工作。这里放宽到 1 小时。
qs_set_scheduler_conf 1 3600000 200
export EXTRA_CONF=""

QS_LAT_P99_TARGET="${QS_LAT_P99_TARGET:-50}"   # 需求：P99 < 50ms
QS_LONG_DB="root.test.qs_0"

log "=== 准备：干净集群 + query_thread_count=1 ==="
export USE_FRAMEWORK=0
if [ "${QS_SKIP_CLEAN:-0}" = "1" ]; then
  # 复用当前集群（已确认数据干净），只重启以应用调度参数。
  # 用于规避 cluster_clean 在高频重启场景下的"残留进程 → 跳过清理 → CN 留旧注册
  # → 新 DN 报 `Reject DataNode registration`"问题。
  log "  跳过清理，仅重启以应用调度参数"
  cluster_stop >/dev/null 2>&1
  cluster_write_conf >/dev/null 2>&1
  qs_apply_scheduler_conf
  cluster_start >/dev/null 2>&1
else
  cluster_stop >/dev/null 2>&1
  for _h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$_h" "sudo pkill -9 -f 'com\.timecho\.iotdb' >/dev/null 2>&1 || true" || true
  done
  sleep 8
  cluster_clean  >/dev/null 2>&1 || warn "cluster_clean 未完全成功"
  # 清理后必须确认 data 目录真的没了：否则 CN 会保留旧节点注册，
  # 新 DN 注册时报 `Reject DataNode registration`（已踩过，整轮 0/5 DN 起不来）。
  for _h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$_h" "test -d $CN_DB_DIR/data" && { warn "$_h data 目录仍在，强制再删"; sshx "$_h" "sudo rm -rf $CN_DB_DIR/data $CN_DB_DIR/logs"; }
  done
  cluster_write_conf >/dev/null 2>&1
  qs_apply_scheduler_conf
  cluster_start >/dev/null 2>&1
fi
wait_cluster_ready || { fail "集群未就绪"; write_result 2>/dev/null || true; exit 1; }

qs_verify_conf_effective

log "=== 确认起始数据为空（避免复用上一轮数据）==="
PRE_POINTS=$(sq "select count(*) from $QS_LONG_DB.**;" 2>/dev/null | grep -oE '\| *[0-9]+' | head -1 | tr -dc '0-9')
log "  造数前点数=${PRE_POINTS:-0}（应为 0 或查询报错）"
if [ "${QS_SKIP_CLEAN:-0}" = "1" ]; then
  note "复用既有集群，跳过『起始库为空』断言（当前残留 ${PRE_POINTS:-0} 点/序列）"
else
  assert_eq "①起始库为空" "${PRE_POINTS:-0}" 0
fi

log "=== 造数（benchmark 写入，目标千万级）==="
# ⚠️ benchmark 的 LOOP = 批次数，每批 BATCH_SIZE_PER_WRITE(默认 10) 点/序列，
#    故 500×10×LOOP×10 点。LOOP=800 → 约 4000 万点（约 30s 造完）。
#    之前用 LOOP=2000 实际写了 **1 亿点**，count(*) 单线程跑不完，长查询必然超时。
qs_load_data 500 10 800 "qs02-load" || true
log "  库: $(sq "show databases;" 2>/dev/null | grep -c 'root.test.qs_0') 个匹配 root.test.qs_0"
POINTS=$(qs_total_points "$QS_LONG_DB")
log "  当前总点数=${POINTS:-?}（序列数=$(qs_series_count "$QS_LONG_DB")）"
assert_ge "①数据已就绪" "${POINTS:-0}" 1000000

log "=== 第一阶段：先测短查询基线（无长查询干扰）==="
QS_QUERY_LOOP="${QS_QUERY_LOOP:-3000}" qs_bench_latest "qs02-baseline"
BASE_P99="$QS_LAT_P99"
BASE_OK="$QS_LAT_OPS"
assert_ge "②基线短查询有成功操作" "$(printf '%.0f' "${BASE_OK:-0}")" 1

log "=== 第二阶段：启动长查询，并在其运行期间打短查询 ==="
# 需求原文：查询**全量数据**，耗时长。count(*) 在聚合下推后只要几秒（实测 40M 点 5s），
# 达不到"长查询"形态；这里改成真正拉取全量结果集（select *），持续数十秒到分钟级。
LONG_SQL="${QS_LONG_SQL:-select * from $QS_LONG_DB.**}"
qs_long_query_bg "$LONG_SQL" /tmp/qs02_long.txt
sleep 3
QS_QUERY_LOOP="${QS_QUERY_LOOP:-3000}" qs_bench_latest "qs02-under-long"
UNDER_P99="$QS_LAT_P99"
UNDER_OK="$QS_LAT_OPS"
UNDER_AVG="$QS_LAT_AVG"

assert_ge "③长查询期间短查询有成功操作" "$(printf '%.0f' "${UNDER_OK:-0}")" 1

log "=== 第三阶段：等长查询结束（验证不被饿死）==="
qs_long_query_wait /tmp/qs02_long.txt
LONG_MS="${QS_LONG_MS:--1}"
LONG_SEC=$(( ${LONG_MS:--1} / 1000 ))

log "=== 判据 ==="
log "  短查询 P99: 基线=${BASE_P99}ms → 长查询期间=${UNDER_P99}ms（目标 < ${QS_LAT_P99_TARGET}ms）"
log "  长查询耗时: ${LONG_SEC}s"

# ① 关键指标：长查询期间短查询 P99 < 50ms
awk -v v="${UNDER_P99:-99999}" -v t="$QS_LAT_P99_TARGET" 'BEGIN{exit !(v+0 < t+0)}' \
  && pass "④长查询期间短查询 P99=${UNDER_P99}ms < ${QS_LAT_P99_TARGET}ms（REQ-01 核心指标达成）" \
  || fail "④长查询期间短查询 P99=${UNDER_P99}ms 未达 ${QS_LAT_P99_TARGET}ms（REQ-01 未达成）"

# ② 短查询不应因长查询而明显劣化（记录为观察项，不设硬阈值）
log "  观察项：P99 放大倍数 = $(awk -v a="$BASE_P99" -v b="$UNDER_P99" 'BEGIN{ if(a+0>0) printf "%.1fx", b/a; else print "N/A"}')"

# ③ 长查询必须完成（rc=0）
if [ "${LONG_MS:--1}" -gt 0 ] 2>/dev/null && [ "${QS_LONG_RC:--1}" = "0" ]; then
  pass "⑤长查询正常结束，耗时 ${LONG_SEC}s（REQ-02 不被饿死）"
else
  fail "⑤长查询未正常结束（超时/被中断）（REQ-02 未达成）"
fi

# 收尾：查询调度用例不做"逐 DN 停机 + 副本比对"（那是内存缓冲区用例的套路），
# 只做轻量收尾：记录数据点数、集群状态、写 RESULT。
log "=== 收尾 ==="
log "  最终总点数=$(qs_total_points "$QS_LONG_DB")"
log "  集群 Running=$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')/8"
write_result 2>/dev/null || true
