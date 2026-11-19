#!/bin/bash
# ============================================================================
# 来源工作项：TDB-1336 explain analyze 功能优化
#   1) SinkNode 增加展示对应的下游节点 ID   → DownStreamPlanNodeId
#   2) ScanNode 中增加 filter 的选择率       → rowScanFilteredRows（verbose 输出）
#   3) ExchangeNode 中增加已处理的 TsBlock size → size_in_bytes
#
#   RC3 已含：#17304 等（见 PLM 修复提交 04fc5c65）
#   验证版本：2.0.13.1 RC3 / ac7f95e（与安全无关，普通模式）
# ============================================================================
RN1336_A=rn1336a
RN1336_B=rn1336b

case_RN217() {
  echo "  --- explain analyze 增强输出（Sink/Scan/Exchange）---"
  local A=$RN1336_A B=$RN1336_B

  Q "drop database if exists $A" >/dev/null 2>&1
  Q "drop database if exists $B" >/dev/null 2>&1
  assert_ok "$(Q "create database $A")" "创建库 $A"
  assert_ok "$(Q "create database $B")" "创建库 $B"
  assert_ok "$(T "insert into root.$A.dev(time, s1) values(1, 1.0)")" "写入 $A 数据"
  T "insert into root.$A.dev(time, s1) values(2, 2.0)" >/dev/null 2>&1
  T "insert into root.$A.dev(time, s1) values(3, 3.0)" >/dev/null 2>&1
  assert_ok "$(T "insert into root.$B.dev(time, s1) values(1, 2.0)")" "写入 $B 数据"
  T "flush" >/dev/null 2>&1

  # 预热：跨库查询在 clean reset 后需等待分区信息就绪，先跑普通查询并重试
  local warm try
  for try in 1 2 3 4 5 6; do
    warm=$(T "select * from root.$A.dev, root.$B.dev" 2>&1)
    echo "$warm" | grep -q "Total line number" && break
    sleep 10
  done

  # 1) SinkNode 下游节点 ID（重试直到 analyze 正常返回）
  local an="" try2
  for try2 in 1 2 3 4 5; do
    an=$(T "explain analyze select * from root.$A.dev, root.$B.dev" 2>&1)
    echo "$an" | grep -q "DownStreamPlanNodeId" && break
    sleep 10
  done
  if ! echo "$an" | grep -q "DownStreamPlanNodeId"; then
    echo "    [debug] 最后一次 analyze 输出（前 8 行）:"
    echo "$an" | head -8 | sed 's/^/      /'
  fi

  # 1b) SinkNode 下游节点 ID 断言
  assert_contains "$an" "DownStreamPlanNodeId" "SinkNode 输出 DownStreamPlanNodeId"
  if echo "$an" | grep -qE "DownStreamPlanNodeId: [0-9]+"; then
    ok "DownStreamPlanNodeId 带有效节点编号（$(echo "$an" | grep -oE 'DownStreamPlanNodeId: [0-9]+' | head -1)）"
  else
    fail "DownStreamPlanNodeId 无有效编号"
  fi

  # 2) ExchangeNode 已处理 TsBlock size
  assert_contains "$an" "ExchangeNode" "跨库查询产生 ExchangeNode"
  if echo "$an" | grep -qE "size_in_bytes: [0-9]+"; then
    ok "ExchangeNode 输出 size_in_bytes（$(echo "$an" | grep -oE 'size_in_bytes: [0-9]+' | head -1)）"
  else
    fail "ExchangeNode 未输出 size_in_bytes"
  fi

  # 3) ScanNode filter 选择率（verbose）
  local van; van=$(T "explain analyze verbose select * from root.$A.dev where s1 > 1" 2>&1)
  assert_contains "$van" "rowScanFilteredRows" "verbose 输出 rowScanFilteredRows（filter 选择率）"
  local rf; rf=$(echo "$van" | grep -oE "rowScanFilteredRows: [0-9]+" | head -1 | awk '{print $2}')
  if [ "${rf:-0}" -ge 1 ] 2>/dev/null; then
    ok "rowScanFilteredRows=$rf（s1>1 过滤掉 3 行中的 1 行）"
  else
    fail "rowScanFilteredRows 数值不符（实际 ${rf:-空}，期望 ≥1）"
  fi

  # 4) 对照：非 verbose 不输出该统计
  local an2; an2=$(T "explain analyze select * from root.$A.dev where s1 > 1" 2>&1)
  if echo "$an2" | grep -q "rowScanFilteredRows"; then
    fail "非 verbose 也输出了 rowScanFilteredRows（verbose 语义不生效）"
  else
    ok "非 verbose 不输出 rowScanFilteredRows（verbose 语义正确）"
  fi

  # 5) 表模型视图同样输出 filter 统计
  assert_ok "$(Q "create view $A.v1(dev string tag) with(auto_sync_schema = true) as root.$A.**")" "创建表视图 $A.v1"
  local tvan; tvan=$(Q "explain analyze verbose select * from $A.v1 where s1 > 1" 2>&1)
  if echo "$tvan" | grep -q "rowScanFilteredRows"; then
    ok "表视图 verbose 也输出 rowScanFilteredRows"
  else
    fail "表视图 verbose 未输出 rowScanFilteredRows"
  fi
  assert_contains "$tvan" "DownStreamPlanNodeId" "表视图 SinkNode 输出 DownStreamPlanNodeId"

  Q "drop database if exists $A" >/dev/null 2>&1
  Q "drop database if exists $B" >/dev/null 2>&1
}

CASES+=(
"RN-217|TDB-1336 explain analyze 增强输出|功能|SinkNode 输出 DownStreamPlanNodeId、ExchangeNode 输出 size_in_bytes、ScanNode 输出 rowScanFilteredRows（verbose）|case_RN217"
)
