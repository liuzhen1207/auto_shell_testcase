#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0426
#   【TIMECHODB-0426】 【树模型-V2.0.5.1 】通过聚合函数max_by或min_by查询时间戳差值报301: Index 2 out of bounds for length 2
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：树模型：通过聚合函数max_by或min_by查询时间戳差值，查询结果集返回正常 复现步骤 （1）IoTDB启动1C1D （2）root用户进入CLI，执行SQL操作  IoTDB> insert into root.s
# ============================================================================
RN0426_SQL=(
"insert into root.sg.d1(time,s1,s2) values(now(),1,1)"
"insert into root.sg.d1(time,s1,s2) values(now(),2,1)"
"insert into root.sg.d1(time,s1,s2) values(now(),3,1)"
"select max_by(time, time_difference(*)),   min_by(time, time_difference(*)) from root.sg.* align by device"
)

case_RN0426() {
  local st out unexpected=0
  for st in "${RN0426_SQL[@]}"; do
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
"TIMECHODB-0426 自动抽取|TIMECHODB-0426|功能|树模型-V2.0.5.1 】通过聚合函数max_by或min_by查询时间戳差值报301: Index 2 out |case_RN0426"
)
