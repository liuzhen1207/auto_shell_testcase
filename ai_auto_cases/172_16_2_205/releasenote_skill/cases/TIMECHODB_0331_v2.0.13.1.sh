#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0331
#   【TIMECHODB-0331】 【表模型V2.0.5.1-RC1】approx_most_frequent函数所需参数为空时，报305内部服务异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：pprox_most_frequent函数所需参数为空时，报错提示显示正确 复现步骤 （1）启动1C1D （2）root用户进入CLI （3）执行SQL查询  create database test_db; use t
# ============================================================================
RN0331_SQL=(
"create database test_db"
)

case_RN0331() {
  local st out unexpected=0
  for st in "${RN0331_SQL[@]}"; do
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
"TIMECHODB-0331 自动抽取|TIMECHODB-0331|功能|表模型V2.0.5.1-RC1】approx_most_frequent函数所需参数为空时，报305内部服务异常|case_RN0331"
)
