#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0699】修改不支持的编码方式，报错信息存在 ERROR 且不友好
#   期望：返回简洁的错误（如 "encoding DICTIONARY does not support INT32"），
#         与 CREATE 的报错风格一致，不打整段堆栈
#   验证版本：2.0.13.1 / ab6d3de
#   判据：①语句被拒绝 ②错误信息包含 "does not support" ③不出现 "at org.apache"
# ============================================================================
RN0699_DB=root.rn0699

case_RN108() {
  local out
  T "drop database $RN0699_DB" >/dev/null 2>&1
  T "create database $RN0699_DB" >/dev/null 2>&1
  out=$(T "create timeSeries $RN0699_DB.wind.a int32")
  assert_ok "$out" "创建 int32 序列"

  out=$(T "alter timeSeries if exists $RN0699_DB.** set STORAGE_PROPERTIES encoding=DICTIONARY")
  echo "  ALTER 返回：$(echo "$out" | head -3 | tr '\n' ' ' | cut -c1-220)"

  if echo "$out" | grep -qiE 'error|exception|失败'; then
    ok "不支持的编码被拒绝（预期行为）"
  else
    fail "DICTIONARY 用于 INT32 竟然成功"
  fi
  if echo "$out" | grep -qi 'does not support'; then
    ok "错误信息含 'does not support' 语义"
  else
    fail "错误信息缺少 'does not support'（实际 $(echo "$out" | head -1 | cut -c1-140)）"
  fi
  if echo "$out" | grep -q 'at org.apache'; then
    fail "返回内容包含完整堆栈（不友好）"
  else
    ok "返回内容不含堆栈"
  fi

  T "drop database $RN0699_DB" >/dev/null 2>&1
}

CASES+=(
"RN-108|TIMECHODB-0699 错误信息|负向|不支持的 encoding=DICTIONARY(INT32) 应返回简洁语义化错误且不带堆栈|case_RN108"
)
