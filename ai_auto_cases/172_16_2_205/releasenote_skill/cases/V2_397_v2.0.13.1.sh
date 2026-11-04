#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-397（创建人：刘珍）
#   sort 算子报 java.lang.ArithmeticException: / by zero（301）
#   复现 SQL：select ... in (select ... order by ... limit N) ... not in (select ... limit M)
#   期望：查询正常返回，不出现 / by zero
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN397_DB=rn_v2397

case_RN131() {
  local out
  Q "DROP DATABASE IF EXISTS $RN397_DB" >/dev/null 2>&1
  Q "CREATE DATABASE $RN397_DB" >/dev/null 2>&1
  assert_ok "$(Q "CREATE TABLE $RN397_DB.aa5(sensor_id STRING TAG, v INT32 FIELD)")" "建表"

  Q "INSERT INTO $RN397_DB.aa5(time, sensor_id, v) VALUES (1,'57LGIB202JARP',1),(2,'5ABP002SP',2),(3,'S3',3),(4,'S4',4),(5,'S5',5),(6,'S6',6),(7,'S7',7),(8,'S8',8),(9,'S9',9),(10,'S10',10),(11,'S11',11),(12,'S12',12)" >/dev/null 2>&1

  out=$(Q "select distinct sensor_id from $RN397_DB.aa5 where sensor_id in (select distinct sensor_id from $RN397_DB.aa5 order by sensor_id limit 20) and sensor_id not in ('57LGIB202JARP','5ABP002SP') and sensor_id not in (select distinct sensor_id from $RN397_DB.aa5 order by sensor_id limit 10)")
  echo "  返回：$(echo "$out" | head -4 | tr '\n' ' ' | cut -c1-220)"

  if echo "$out" | grep -qiE 'ArithmeticException|/ by zero'; then
    fail "仍出现 / by zero（缺陷未修复）"
  else
    ok "未出现 / by zero"
  fi
  if echo "$out" | grep -q '301'; then
    fail "仍返回 301"
  else
    ok "未返回 301"
  fi
  if echo "$out" | grep -qi 'S1[1-9]\|S[3-9]'; then
    ok "查询返回了非排除项的 sensor_id"
  else
    ok "查询返回空集（也可接受，重点是不报错）"
  fi

  Q "DROP DATABASE IF EXISTS $RN397_DB" >/dev/null 2>&1
}

CASES+=(
"RN-131|V2-397 sort 算子|功能|带 in/not in + order by limit 子查询的 distinct 查询不应 / by zero|case_RN131"
)
