#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0251
#   【TIMECHODB-0251】 【表模型-SQL】distinct查询中，非法格式校验状态码需要优化
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：【表模型-SQL】distinct查询中，非法格式校验状态码由301需改为701 复现步骤   select distinct(time,int32,double) from t1;    研发侧 问题原因 image.
# ============================================================================
RN0251_SQL=(
"select distinct(time,int32,double) from t1"
)

case_RN0251() {
  local st out unexpected=0
  for st in "${RN0251_SQL[@]}"; do
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
"TIMECHODB-0251 自动抽取|TIMECHODB-0251|功能|表模型-SQL】distinct查询中，非法格式校验状态码需要优化|case_RN0251"
)
