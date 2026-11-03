#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0306
#   【TIMECHODB-0306】 Join + 聚合下推 查询场景出现异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：执行目标查询： 打印查询计划观察到 Sort 被正常消除（类似左侧孩子） 查询正常执行 复现步骤 数据准备  create database test;  use test;  create table table1(d
# ============================================================================
RN0306_SQL=(
"create database test"
"create table table1(device string tag, value int32 field)"
"insert into table1(time,device,value) values(2020-01-01 00:00:01.000,'d1',1)"
"select * from ( select date_bin(1ms,time) as date,count(*)from table1 group by date_bin(1ms,time)) t0 join ( select date_bin(1ms,time) as date,count(*)from table1 group by date_bin(1ms,time)) t1  on t0.date = t1.date"
)

case_RN0306() {
  local st out unexpected=0
  for st in "${RN0306_SQL[@]}"; do
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
"TIMECHODB-0306 自动抽取|TIMECHODB-0306|功能|Join + 聚合下推 查询场景出现异常|case_RN0306"
)
