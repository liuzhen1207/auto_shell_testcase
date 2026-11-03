#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0341
#   【TIMECHODB-0341】 【窗口函数】窗口函数offset PRECEDING和offset FOLLOWING中的允许offset为取值不合法但是没有报错，与MySQL不一致
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：这些情况需要报错  复现步骤  create database d1 use d1 create table device_flow (device string tag, flow int64 field) inser
# ============================================================================
RN0341_SQL=(
"create database d1"
"create table device_flow (device string tag, flow int64 field)"
"insert into device_flow values (1970-01-01T08:00:00.000+08:00, 'd0', 3)"
"insert into device_flow values (1970-01-01T08:00:00.001+08:00, 'd0', 5)"
"insert into device_flow values (1970-01-01T08:00:00.002+08:00, 'd0', 3)"
"insert into device_flow values (1970-01-01T08:00:00.003+08:00, 'd0', 1)"
"insert into device_flow values (1970-01-01T08:00:00.004+08:00, 'd1', 2)"
"insert into device_flow values (1970-01-01T08:00:00.005+08:00, 'd1', 4)"
"SELECT time, device, flow, count(flow) OVER(PARTITION BY device ROWS BETWEEN -1 PRECEDING AND -1 FOLLOWING)FROM device_flow"
)

case_RN0341() {
  local st out unexpected=0
  for st in "${RN0341_SQL[@]}"; do
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
"TIMECHODB-0341 自动抽取|TIMECHODB-0341|功能|窗口函数】窗口函数offset PRECEDING和offset FOLLOWING中的允许offset为取值不合法|case_RN0341"
)
