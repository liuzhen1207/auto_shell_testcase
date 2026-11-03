#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0318
#   【TIMECHODB-0318】 多层 Join Using 嵌套使用时消除不必要的 SortNode
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：SortNode 被消除 image.png  复现步骤 创建数据  create database test;  use test;  create table table1(device string tag, va
# ============================================================================
RN0318_SQL=(
"create database test"
"create table table1(device string tag, value int32 field)"
"insert into table1(time,device,value) values(2020-01-01 00:00:01.000,'d1',1)"
"Explain 查询"
"explain select * from table1 t1 full join table1 using (time) full join table1 using (time)"
)

case_RN0318() {
  local st out unexpected=0
  for st in "${RN0318_SQL[@]}"; do
    out=$( Q "$st" )
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
"TIMECHODB-0318 自动抽取|TIMECHODB-0318|功能|多层 Join Using 嵌套使用时消除不必要的 SortNode|case_RN0318"
)
