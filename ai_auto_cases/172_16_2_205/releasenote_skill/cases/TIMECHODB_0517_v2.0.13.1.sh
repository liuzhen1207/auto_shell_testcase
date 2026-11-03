#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0517
#   【TIMECHODB-0517】 【v2.0.6.1】查询写回报错“Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 301: org.apache.tsfile.read.co
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：预期成功执行。  复现步骤 简易复现步骤：  create database test; use test; create table source(s1 boolean field, device_id string 
# ============================================================================
RN0517_SQL=(
"create database test"
"create table source(s1 boolean field, device_id string tag)"
"create table target(device_id string tag, s1 boolean field)"
"insert into source(time, device_id, s1) values(1, 'd1', false)"
"INSERT INTO target(time, device_id, s1) SELECT time, device_id, s1 FROM source"
"create table t1(device tag,int32 int32)"
"insert into t1(time,device,int32) select time,device_id,s_100 from table_0"
)

case_RN0517() {
  local st out unexpected=0
  for st in "${RN0517_SQL[@]}"; do
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
"TIMECHODB-0517 自动抽取|TIMECHODB-0517|功能|v2.0.6.1】查询写回报错“Msg: org.apache.iotdb.jdbc.IoTDBSQLExcepti|case_RN0517"
)
