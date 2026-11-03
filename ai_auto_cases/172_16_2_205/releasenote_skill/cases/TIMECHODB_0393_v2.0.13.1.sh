#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0393
#   【TIMECHODB-0393】 Limit 在查询时被不正确消除
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询结果为 1； 观察查询计划发现 DeviceTableScanNode 的 pushDownLimit 为 1。  复现步骤  // 插入数据 create database test; use test;  cre
# ============================================================================
RN0393_SQL=(
"create database test"
"create table table2(device_id string tag, s1 int32 field)"
"insert into table2(time,device_id,s1) values(1,'d1',1)"
"insert into table2(time,device_id,s1) values(2,'d1',2)"
"select count(*) from (select * from table2 where device_id = 'd1' order by time limit 1)"
)

case_RN0393() {
  local st out unexpected=0
  for st in "${RN0393_SQL[@]}"; do
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
"TIMECHODB-0393 自动抽取|TIMECHODB-0393|功能|Limit 在查询时被不正确消除|case_RN0393"
)
