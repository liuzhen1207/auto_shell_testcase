#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0345
#   【TIMECHODB-0345】 【窗口函数】窗口函数查询带有空值的数据会有多种问题
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：对于空值情况的数据应该正常查询  复现步骤 问题一复现语句  create database d1 use d1 create table device_flow (device string tag, id strin
# ============================================================================
RN0345_SQL=(
"create database d1"
"create table device_flow (device string tag, id string attribute, flow int64 field)"
"insert into device_flow values (1970-01-01T08:00:00.000+08:00, 'd0','d0', 3)"
"insert into device_flow values (1970-01-01T08:00:00.001+08:00, 'd0','d0', 5)"
"insert into device_flow values (1970-01-01T08:00:00.002+08:00, null,null, null)"
"insert into device_flow values (1970-01-01T08:00:00.003+08:00, 'd0','d0', 1)"
"insert into device_flow values (1970-01-01T08:00:00.004+08:00, 'd1','d1', 2)"
"insert into device_flow values (1970-01-01T08:00:00.005+08:00, 'd1','d1', 4)"
"SELECT time, device, flow, count(flow) OVER(PARTITION BY DEVICE ORDER BY flow)FROM device_flow"
"create table device_flow (device string tag, flow int64 field)"
"insert into device_flow values (1970-01-01T08:00:00.000+08:00, 'd0', 3)"
"insert into device_flow values (1970-01-01T08:00:00.001+08:00, 'd0', 5)"
"insert into device_flow values (1970-01-01T08:00:00.002+08:00, null, null)"
"insert into device_flow values (1970-01-01T08:00:00.003+08:00, 'd0', 1)"
"insert into device_flow values (1970-01-01T08:00:00.004+08:00, 'd1', 2)"
"insert into device_flow values (1970-01-01T08:00:00.005+08:00, 'd1', 4)"
)

case_RN0345() {
  local st out unexpected=0
  for st in "${RN0345_SQL[@]}"; do
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
"TIMECHODB-0345 自动抽取|TIMECHODB-0345|功能|窗口函数】窗口函数查询带有空值的数据会有多种问题|case_RN0345"
)
