#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0686】数据删除：WHERE 用 and 连接两个原子表达式、
#   且时间最小值大于最大值时，报底层 305，需要给出明确报错
#   修复方向：左区间值 > 右区间值时抛 IoTDBSQLException 并给出明确提示
#   验证版本：2.0.13.1 / ab6d3de
#   判据：delete ... where time > 4 and time < 0
#         ①仍然失败（这是非法区间）②但错误码不再是底层 305（tsfile TimeRange）
#         ③错误信息应包含语义化提示（time/时间/区间/range 之一）
# ============================================================================
RN0686_DB=root.rn0686

case_RN102() {
  local out
  T "drop database $RN0686_DB" >/dev/null 2>&1
  T "create database $RN0686_DB" >/dev/null 2>&1
  T "create timeseries $RN0686_DB.g_0.d_2.s_0 int32" >/dev/null 2>&1
  out=$(T "insert into $RN0686_DB.g_0.d_2(time,s_0) values(1,1)")
  assert_ok "$out" "准备数据"

  out=$(T "delete from $RN0686_DB.g_0.d_2.s_0 where time > 4 and time < 0")
  echo "  DELETE 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-220)"

  # 非法区间必须失败
  if echo "$out" | grep -qiE 'error|exception|失败'; then
    ok "非法时间区间被拒绝（预期行为）"
  else
    fail "非法时间区间居然成功，行为异常"
  fi
  # 不应暴露底层 tsfile 305
  if echo "$out" | grep -q '305'; then
    fail "仍返回底层 305（未完成错误信息优化）"
  else
    ok "不再返回底层 305"
  fi
  # 应有语义化提示
  if echo "$out" | grep -qiE 'time|时间|range|区间'; then
    ok "错误信息含时间/区间语义"
  else
    fail "错误信息缺少可读语义（实际 $(echo "$out" | head -1 | cut -c1-120)）"
  fi

  # 对照：合法区间应正常删除
  out=$(T "delete from $RN0686_DB.g_0.d_2.s_0 where time > 0 and time < 4")
  assert_ok "$out" "对照：合法区间删除成功"

  T "drop database $RN0686_DB" >/dev/null 2>&1
}

CASES+=(
"RN-102|TIMECHODB-0686 错误信息|负向|DELETE 时间区间 min>max 应给出明确错误而非底层 305|case_RN102"
)
