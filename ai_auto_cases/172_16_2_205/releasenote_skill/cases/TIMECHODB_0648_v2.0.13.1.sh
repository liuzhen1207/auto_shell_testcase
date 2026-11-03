#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0648】两表 JOIN 后使用 last 聚合函数报
#   701: Column 'time' is ambiguous（parser 给 last 隐式塞了未限定的 time 列）
#   验证版本：2.0.13.1 / ab6d3de
#   判据：JOIN + last() 分组查询能正常返回，不再出现 "Column 'time' is ambiguous"
# ============================================================================
RN0648_DB=rn0648_db

case_RN118() {
  local out
  Q "DROP DATABASE IF EXISTS $RN0648_DB" >/dev/null 2>&1
  assert_ok "$(Q "CREATE DATABASE $RN0648_DB")" "建库"
  assert_ok "$(Q "CREATE TABLE $RN0648_DB.t1(device_id STRING TAG, code STRING TAG, s1 FLOAT)")" "建表 t1"
  assert_ok "$(Q "CREATE TABLE $RN0648_DB.t2(device_id STRING TAG, s2 FLOAT)")" "建表 t2"

  Q "INSERT INTO $RN0648_DB.t1(time, device_id, code, s1) VALUES (1,'d1','c1',1.0),(2,'d1','c1',2.0)" >/dev/null 2>&1
  Q "INSERT INTO $RN0648_DB.t2(time, device_id, s2) VALUES (1,'d1',10.0),(2,'d1',20.0)" >/dev/null 2>&1

  out=$(Q "SELECT t1.code, date_bin(15m, t2.time), t2.device_id, last(t2.s2) FROM $RN0648_DB.t1, $RN0648_DB.t2 WHERE t1.device_id = t2.device_id GROUP BY t1.code, date_bin(15m, t2.time), t2.device_id")
  echo "  查询返回：$(echo "$out" | head -6 | tr '\n' ' ' | cut -c1-240)"

  if echo "$out" | grep -qi "ambiguous"; then
    fail "仍报 Column 'time' is ambiguous"
  else
    ok "不再报 time 列歧义"
  fi
  if echo "$out" | grep -qiE 'error|exception|701'; then
    fail "查询仍报错（$(echo "$out" | head -1 | cut -c1-140)）"
  else
    ok "查询正常返回"
  fi
  if echo "$out" | grep -q 'c1'; then
    ok "结果包含期望的 code=c1 行"
  else
    fail "结果缺少 c1 行（$(echo "$out" | tr '\n' ' ' | cut -c1-160)）"
  fi

  Q "DROP DATABASE IF EXISTS $RN0648_DB" >/dev/null 2>&1
}

CASES+=(
"RN-118|TIMECHODB-0648 JOIN 聚合|功能|两表 JOIN 后 last() 分组查询不应报 time 字段歧义|case_RN118"
)
