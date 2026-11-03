#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0185
#   【TIMECHODB-0185】 group 超过 1024，部分聚合函数（First、Last、Sum、Extreme）查询报 BigArrary NPE
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询正常执行  复现步骤 数据构造 create database test; use test; create table table1(device string field, s1 int32 field); //
# ============================================================================
RN0185_SQL=(
"create database test"
"create table table1(device string field, s1 int32 field)"
"insert into table1(time,device,s1) values(1,'d1',1)"
"insert into table1(time,device,s1) values(2,'d2',2)"
"insert into table1(time,device,s1) values(3,'d3',3)"
"insert into table1(time,device,s1) values(1025,'d1025',1025)"
"select first(s1) from table1 group by s1"
"select last(s1) from table1 group by s1"
"select sum(s1) from table1 group by s1"
"select extreme(s1) from table1 group by s1"
)

case_RN0185() {
  local st out unexpected=0
  for st in "${RN0185_SQL[@]}"; do
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
"TIMECHODB-0185 自动抽取|TIMECHODB-0185|功能|group 超过 1024，部分聚合函数（First、Last、Sum、Extreme）查询报 BigArrary |case_RN0185"
)
