#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0038
#   【TIMECHODB-0038】 [table]没有任何列的table可以创建，但是不能写入
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：
# ============================================================================
RN0038_SQL=(
"create database a"
"create table a.empty_cols()"
"insert into a.empty_cols(time)values(1),(2)"
)

case_RN0038() {
  local st out unexpected=0
  for st in "${RN0038_SQL[@]}"; do
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
"TIMECHODB-0038 自动抽取|TIMECHODB-0038|功能|table]没有任何列的table可以创建，但是不能写入|case_RN0038"
)
