#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1352
#   表视图（定义基于树模型非对齐设备）的 last 查询可优化：
#   原实现不下推、且为正序 scan，会扫描所有数据；
#   期望：非对齐设备虽然聚合不能下推（指不下推到存储层统计），
#         但 last 查询应优化为倒序查，避免扫描全部数据。
#
#   RC3 状态（本用例验证点）：
#     1) 聚合下推：EXPLAIN 出现 NonAlignedAggregationTreeDeviceViewScanNode
#        且该节点内含 last(...) → 下推已生效
#     2) 倒序扫描：该节点 ScanOrder 应为 DESC，且 last 耗时显著小于全量 count
#        → 实测为 ASC 且耗时与 count/first 相同
#
#   验证版本：2.0.13.1 RC3 / ac7f95e（与安全无关，普通模式）
# ============================================================================
RN1352_DB=rn1352_db
RN1352_ROWS=50000

case_RN216() {
  echo "  --- 非对齐设备表视图 last 查询：下推 + 倒序扫描 ---"
  local D=$RN1352_DB
  Q "drop database if exists $D" >/dev/null 2>&1
  assert_ok "$(Q "create database $D")" "创建数据库 $D"
  # 非对齐设备：d1 / d2 各自独立 timeseries
  assert_ok "$(T "create timeseries root.$D.d1.s1 double")" "创建非对齐设备 d1 序列"
  assert_ok "$(T "create timeseries root.$D.d2.s1 double")" "创建非对齐设备 d2 序列"

  # 写数据（5000 行/批）
  local dev chunk i t v vals
  for dev in d1 d2; do
    for chunk in $(seq 1 $((RN1352_ROWS / 5000))); do
      vals=""
      for i in $(seq 1 5000); do
        t=$(( (chunk-1)*5000 + i )); v=$(( t % 89 ))
        vals="$vals($t,$v.0),"
      done
      vals=${vals%,}
      T "insert into root.$D.$dev(time,s1) values $vals" >/dev/null 2>&1
    done
  done
  local cnt; cnt=$(T "select count(s1) from root.$D.d1" 2>&1 | grep -E '^\|' | tail -1 | tr -dc '0-9')
  [ "${cnt:-0}" -ge "$RN1352_ROWS" ] && ok "写入数据完成（d1=$cnt 行）" || fail "数据写入不足（d1=${cnt:-0}）"

  assert_ok "$(Q "create view $D.v1(dev string tag) with(auto_sync_schema = true) as root.$D.**")" "创建表视图 v1"

  # 1) 聚合下推
  local plan; plan=$(Q "explain select last(s1) from $D.v1" 2>&1)
  assert_contains "$plan" "NonAlignedAggregationTreeDeviceViewScanNode" "EXPLAIN 出现非对齐视图聚合下推算子"
  if echo "$plan" | grep -q "NonAlignedAggregationTreeDeviceViewScanNode"; then
    local seg; seg=$(echo "$plan" | sed -n '/NonAlignedAggregationTreeDeviceViewScanNode/,/└/p')
    echo "$seg" | grep -q "last(" && ok "last 聚合已下推到 scan 节点" || fail "last 聚合未出现在 scan 节点内（未下推）"
  fi

  # 2) 倒序扫描
  local order; order=$(echo "$plan" | grep -m1 "ScanOrder" | tr -d ' ')
  if echo "$order" | grep -q "ScanOrder:DESC"; then
    ok "scan 顺序为 DESC（倒序，符合优化预期）"
  else
    fail "scan 顺序为 ${order:-未知}，期望 DESC（未按 TDB-1352 优化为倒序）"
  fi

  # 3) 耗时对比：倒序查应远快于全量 count
  local t0 t1 last_ms cnt_ms
  t0=$(date +%s%N); Q "select last(s1) from $D.v1" >/dev/null 2>&1; t1=$(date +%s%N)
  last_ms=$(( (t1-t0)/1000000 ))
  t0=$(date +%s%N); Q "select count(s1) from $D.v1" >/dev/null 2>&1; t1=$(date +%s%N)
  cnt_ms=$(( (t1-t0)/1000000 ))
  echo "    last=${last_ms}ms count=${cnt_ms}ms"
  if [ "$cnt_ms" -gt 0 ] && [ "$last_ms" -lt $(( cnt_ms / 3 )) ]; then
    ok "last 耗时显著低于全量 count（${last_ms}ms < ${cnt_ms}ms/3），未全表扫描"
  else
    fail "last 耗时 ${last_ms}ms 与全量 count ${cnt_ms}ms 相当，仍扫描全部数据"
  fi

  # 4) 功能正确性：last 返回最大时间点的值
  local res; res=$(Q "select last(s1) from $D.v1" 2>&1 | grep -E '^\|' | head -2 | tail -1 | tr -dc '0-9.')
  local expect=$(( (RN1352_ROWS % 89) ))
  if [ "${res:-}" = "${expect}.0" ] || [ "${res:-}" = "$expect" ]; then
    ok "last 结果正确（$res）"
  else
    fail "last 结果错误（实际 ${res:-空}，期望 ${expect}）"
  fi

  Q "drop database if exists $D" >/dev/null 2>&1
}

CASES+=(
"RN-216|TDB-1352 非对齐视图 last 查询下推与倒序|性能|EXPLAIN 显示聚合下推且 ScanOrder=DESC；last 耗时应远低于全量扫描|case_RN216"
)
