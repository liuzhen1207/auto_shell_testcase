#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0554
#   【TIMECHODB-0554】 [2.0.6.1][aggregate-processor]负数时间戳没有被处理
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤  insert into root.sg.single(time,s0) values(-2220000,-2220000),(-220000,-220000),(-20000,-20000),(-10000,
# ============================================================================
RN0554_SQL=(
"insert into root.sg.single(time,s0) values(-2220000,-2220000),(-220000,-220000),(-20000,-20000),(-10000,-10000),(-1000,-1000),(-1,-1)"
"insert into root.sg.single(time,s0) values(2220000,2220000),(1706670000,1706670000),(1706676000,1706676000),(1706674000,1706674000)"
"create pipe test_disorder  with source('path'='root.sg.single.**') with processor ('processor'='aggregate-processor','output.database'='root.aggr.disorder','sliding.boundary-time'='0','sliding.interval-seconds'='60','operators'='peak') with sink('sink'='write-back-sink')"
)

case_RN0554() {
  local st out unexpected=0
  for st in "${RN0554_SQL[@]}"; do
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
"TIMECHODB-0554 自动抽取|TIMECHODB-0554|功能|2.0.6.1][aggregate-processor]负数时间戳没有被处理|case_RN0554"
)
