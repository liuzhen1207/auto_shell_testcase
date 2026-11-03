#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0444
#   【TIMECHODB-0444】 [ 树转表 ] alter view view_not_exist add column col from col; CN 空指针需要处理
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：无空指针  复现步骤 干净环境，1C1D set sql_dialect=table; Create database db; Use db; alter view view_not_exist add column c
# ============================================================================
RN0444_SQL=(
"set sql_dialect=table"
"Create database db"
"alter view view_not_exist add column col from col"
)

case_RN0444() {
  local st out unexpected=0
  for st in "${RN0444_SQL[@]}"; do
    out=$( T "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      unexpected=$((unexpected+1))
      fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"TIMECHODB-0444 自动抽取|TIMECHODB-0444|功能|树转表 ] alter view view_not_exist add column col from col; C|case_RN0444"
)
