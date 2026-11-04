#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-378（创建人：刘珍）
#   查询 cast(1.1 as float) 报
#   java.lang.UnsupportedOperationException: DoubleColumn（预期应成功）
#   期望：cast 到 float 正常返回
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN378_DB=rn_v2378

case_RN127() {
  local out
  out=$(Q "select cast(1.1 as float)")
  echo "  cast 返回：$(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"

  if echo "$out" | grep -qi 'UnsupportedOperationException'; then
    fail "仍抛 UnsupportedOperationException（缺陷未修复）"
  else
    ok "未抛 UnsupportedOperationException"
  fi
  if echo "$out" | grep -qE '\|[[:space:]]*1\.1[[:space:]]*\|'; then
    ok "cast 结果为 1.1"
  else
    fail "cast 结果异常（$(echo "$out" | tr '\n' ' ' | cut -c1-120)）"
  fi

  # 表模型字段上的 cast
  Q "DROP DATABASE IF EXISTS $RN378_DB" >/dev/null 2>&1
  Q "CREATE DATABASE $RN378_DB" >/dev/null 2>&1
  Q "CREATE TABLE $RN378_DB.t1(device_id STRING TAG, sensor_id STRING TAG, value FLOAT FIELD)" >/dev/null 2>&1
  Q "INSERT INTO $RN378_DB.t1(time, device_id, sensor_id, value) VALUES (1,'d1','s1',9.8),(2,'d2','s2',2.8)" >/dev/null 2>&1
  out=$(Q "select cast(value as float) from $RN378_DB.t1")
  echo "  字段 cast 返回：$(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
  if echo "$out" | grep -qi 'UnsupportedOperationException'; then
    fail "字段 cast 仍抛 UnsupportedOperationException"
  else
    ok "字段 cast 正常"
  fi

  Q "DROP DATABASE IF EXISTS $RN378_DB" >/dev/null 2>&1
}

CASES+=(
"RN-127|V2-378 cast 查询|功能|select cast(1.1 as float) 不应抛 UnsupportedOperationException|case_RN127"
)
