#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0684】GROUP BY + ORDER BY + LIMIT 时，查询结果错误
#   版本背景：记录于 2.x，修复方向 = "禁止 limit/offset 下推至 AggTableScanNode"
#   验证版本：2.0.13.1 / ab6d3de
#   场景：GROUP BY 后带 ORDER BY + LIMIT，若 limit 被下推到扫描层，
#         聚合会作用在"被截断后的原始数据"上，导致 count 变小。
#   判据：select device_id, date_bin(1h,time), count(s1) ... limit 1
#         预期返回 d1 的 count = 2（修复前为 1）
# ============================================================================
RN0684_DB=rn0684_db

case_RN101() {
  local out rows
  Q "DROP DATABASE IF EXISTS $RN0684_DB" >/dev/null 2>&1
  out=$(Q "CREATE DATABASE $RN0684_DB")
  assert_ok "$out" "建库"

  out=$(Q "CREATE TABLE $RN0684_DB.t1(device_id STRING TAG, s1 FLOAT)")
  assert_ok "$out" "建表"

  out=$(Q "INSERT INTO $RN0684_DB.t1(time, device_id, s1) VALUES (0,'d1',1.0),(1,'d1',1.0),(0,'d2',1.0),(1,'d2',1.0)")
  assert_ok "$out" "写入 4 行（d1×2 / d2×2）"

  out=$(Q "SELECT device_id, date_bin(1h, time), count(s1) FROM $RN0684_DB.t1 GROUP BY 1,2 ORDER BY device_id, date_bin(1h, time) LIMIT 1")
  echo "  limit 1 结果：$(echo "$out" | tr '\n' ' ' | cut -c1-200)"

  # 修复后：第一行应是 d1 且 count = 2
  if echo "$out" | grep -qE '\|[[:space:]]*d1[[:space:]]*\|'; then
    ok "返回首行为 d1"
  else
    fail "返回首行不是 d1（实际 $(echo "$out" | sed -n '2p' | cut -c1-80)）"
  fi
  if echo "$out" | grep -qE '\|[[:space:]]*2[[:space:]]*\|'; then
    ok "d1 的 count = 2（修复前错误地返回 1）"
  else
    fail "d1 的 count 不是 2（limit 可能仍被下推到聚合之下）"
  fi

  # 对照：不加 limit 时结果必须同样是 2
  out=$(Q "SELECT device_id, date_bin(1h, time), count(s1) FROM $RN0684_DB.t1 GROUP BY 1,2 ORDER BY device_id")
  if echo "$out" | grep -qE '\|[[:space:]]*2[[:space:]]*\|'; then
    ok "对照（无 limit）：count = 2"
  else
    fail "对照（无 limit）：count 不是 2，用例前提不成立"
  fi

  Q "DROP DATABASE IF EXISTS $RN0684_DB" >/dev/null 2>&1
}

CASES+=(
"RN-101|TIMECHODB-0684 查询正确性|功能|GROUP BY + ORDER BY + LIMIT 不应把 limit 下推到聚合之下（d1 count 应为 2）|case_RN101"
)
