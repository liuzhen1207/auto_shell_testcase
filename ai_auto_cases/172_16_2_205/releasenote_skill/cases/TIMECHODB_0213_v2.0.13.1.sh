#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0213
#   【TIMECHODB-0213】聚合查询 distinct 命中聚合下推优化且与 group by date_bin 联用时执行异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询正常执行  复现步骤  // 数据构造 create database test; use test; create table table1(device string tag, s1 int32 field); 
# ============================================================================
RN0213_SQL=(
"create database test"
"create table table1(device string tag, s1 int32 field)"
"insert into table1(time,device,s1) values(1,'d1',1)"
"select count(distinct device) from table1 group by date_bin(1ms, time)"
)

case_RN0213() {
  local st out unexpected=0
  for st in "${RN0213_SQL[@]}"; do
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
"TIMECHODB-0213 自动抽取|TIMECHODB-0213|功能|聚合查询 distinct 命中聚合下推优化且与 group by date_bin 联用时执行异常|case_RN0213"
)
