#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-430（创建人：刘珍）
#   修改数据类型为 BLOB 后，last 查询报
#   StatisticsClassException: BLOB statistics does not support: last（301）
#   期望：last 查询不应因 BLOB 统计信息抛异常（返回可读错误或结果）
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN430_DB=rn_v2430

case_RN132() {
  local out
  Q "DROP DATABASE IF EXISTS $RN430_DB" >/dev/null 2>&1
  Q "CREATE DATABASE $RN430_DB" >/dev/null 2>&1
  assert_ok "$(Q "CREATE TABLE $RN430_DB.t1(device_id STRING TAG, s_blob BLOB FIELD, s_int INT32 FIELD)")" "建表（含 BLOB 列）"
  Q "INSERT INTO $RN430_DB.t1(time, device_id, s_blob, s_int) VALUES (1,'d1',X'6970',1),(2,'d1',X'6971',2)" >/dev/null 2>&1

  out=$(Q "SELECT device_id, last(time), last_by(s_blob, time) FROM $RN430_DB.t1 WHERE device_id = 'd1' GROUP BY device_id")
  echo "  last(BLOB) 返回：$(echo "$out" | head -3 | tr '\n' ' ' | cut -c1-220)"

  if echo "$out" | grep -qi 'StatisticsClassException'; then
    fail "仍抛 StatisticsClassException（缺陷未修复）"
  else
    ok "未抛 StatisticsClassException"
  fi
  if echo "$out" | grep -qi 'BLOB statistics does not support'; then
    fail "仍出现 'BLOB statistics does not support'"
  else
    ok "未出现 BLOB statistics 不支持的内部异常文案"
  fi

  # 对照：普通列 last 必须正常
  out=$(Q "SELECT device_id, last(s_int) FROM $RN430_DB.t1 WHERE device_id = 'd1' GROUP BY device_id")
  if echo "$out" | grep -qE '\|[[:space:]]*2[[:space:]]*\|'; then
    ok "对照：普通列 last 返回 2"
  else
    fail "对照：普通列 last 异常（$(echo "$out" | tr '\n' ' ' | cut -c1-140)）"
  fi

  Q "DROP DATABASE IF EXISTS $RN430_DB" >/dev/null 2>&1
}

CASES+=(
"RN-132|V2-430 BLOB 聚合|功能|BLOB 列的 last/last_by 不应抛 StatisticsClassException|case_RN132"
)
