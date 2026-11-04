#!/bin/bash
# ============================================================================
# 来源缺陷单：PingCode V2-374（创建人：刘珍）
#   树模型修改数据类型：类型名小写时修改失败
#   java.lang.IllegalArgumentException: No enum constant TSDataType.text
#   期望：大小写不敏感，text 与 TEXT 行为一致
#   验证版本：2.0.13.1 / ab6d3de
# ============================================================================
RN374_DB=root.v2374

case_RN126() {
  local out ts
  T "drop database $RN374_DB" >/dev/null 2>&1
  T "create database $RN374_DB" >/dev/null 2>&1
  assert_ok "$(T "create timeseries $RN374_DB.d1.col blob")" "创建 BLOB 序列"
  assert_ok "$(T "insert into $RN374_DB.d1(time,col) values(1,X'6970')")" "写入 BLOB 数据"

  out=$(T "alter timeseries $RN374_DB.d1.col set data type text")
  echo "  小写改名返回：$(echo "$out" | head -1 | cut -c1-160)"
  if echo "$out" | grep -qiE 'IllegalArgumentException|No enum constant|305'; then
    fail "小写数据类型仍报错（缺陷未修复）"
  else
    ok "小写 text 不再报枚举错误"
  fi
  assert_ok "$out" "小写 text 修改成功"

  ts=$(T "show timeseries $RN374_DB.d1.col")
  if echo "$ts" | grep -q 'TEXT'; then
    ok "序列类型已变为 TEXT"
  else
    fail "序列类型未变为 TEXT（$(echo "$ts" | tail -2 | tr '\n' ' ' | cut -c1-120)）"
  fi

  T "drop database $RN374_DB" >/dev/null 2>&1
}

CASES+=(
"RN-126|V2-374 数据类型大小写|功能|alter timeseries set data type text（小写）应与 TEXT 一致成功|case_RN126"
)
