#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0446
#   【TIMECHODB-0446】 TIMESTAMP 类型聚合查询结果错误
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询结果正确 image.png   复现步骤  create database test;  use test; create table tableD(device STRING TAG, value TIMESTA
# ============================================================================
RN0446_SQL=(
"create database test"
"create table tableD(device STRING TAG, value TIMESTAMP FIELD)"
"insert into tableD(time,device,value) values('2020-01-01 00:00:07.000', 'd2', '1970-01-01 00:00:00.000')"
"select last(value),first(value),last_by(value,time),first_by(value,time),max(value),min(value) from tableD"
)

case_RN0446() {
  local st out unexpected=0
  for st in "${RN0446_SQL[@]}"; do
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
"TIMECHODB-0446 自动抽取|TIMECHODB-0446|功能|TIMESTAMP 类型聚合查询结果错误|case_RN0446"
)
