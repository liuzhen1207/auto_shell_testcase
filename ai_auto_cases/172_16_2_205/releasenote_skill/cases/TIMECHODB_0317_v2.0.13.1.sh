#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0317
#   【TIMECHODB-0317】 【表模型】对于不支持ASOF RIGHT JOIN查询时，报305异常内部错误
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：对于不支持ASOF RIGHT JOIN查询时，返回具体的状态码以及错误信息  复现步骤 （1）commit id: 4042fe1d5b50907b6fe38b1c16ba0318b912478c （2）启动1C1D 
# ============================================================================
RN0317_SQL=(
"create database test_db"
"create table t1(id TAG,temperature FLOAT, status BOOLEAN, duration timestamp)"
"create table t2(id TAG,temperature FLOAT, status BOOLEAN, duration timestamp)"
"create table t3(id TAG,temperature FLOAT, status BOOLEAN, duration timestamp)"
"show tables"
"insert into t1(time, id, temperature, status, duration) values(1000, 'd1', 22.2, false, 3600000)"
"insert into t1(time, id, temperature, status, duration) values(2000, 'd2', 20.1, true, 86400000)"
"insert into t1(time, id, temperature, status, duration) values(3000, 'd1', 19.2, false, 43200000)"
"insert into t1(time, id, temperature, status, duration) values(4000, 'd2', 23.11, true, 604800000)"
"insert into t1(time, id, temperature, status, duration) values(5000, 'd1', 25.13, false, 432000000)"
"insert into t1(time, id, temperature, status, duration) values(6000, 'd2', 24.4, true, 2592000000)"
"insert into t2(time, id, temperature, status, duration) values(1000, 'd1', 32.1, false, 3600000)"
"insert into t2(time, id, temperature, status, duration) values(3000, 'd2', 20.1, true, 86400000)"
"insert into t2(time, id, temperature, status, duration) values(4000, 'd1', 19.9, true, 43200000)"
"insert into t2(time, id, temperature, status, duration) values(6000, 'd2', 22.3, true, 604800000)"
"insert into t2(time, id, temperature, status, duration) values(8000, 'd1', 26.3, false, 432000000)"
"insert into t2(time, id, temperature, status, duration) values(9000, 'd2', 24.5, true, 2592000000)"
"insert into t3(time, id, temperature, status, duration) values(1000, 'd1', 26.2, false, 3600000)"
"insert into t3(time, id, temperature, status, duration) values(5000, 'd2', 20.1, true, 86400000)"
"insert into t3(time, id, temperature, status, duration) values(8000, 'd1', 19.9, false, 43200000)"
"insert into t3(time, id, temperature, status, duration) values(9000, 'd2', 24.4, true, 604800000)"
"insert into t3(time, id, temperature, status, duration) values(10000, 'd1', 25.5, false, 259200000)"
"insert into t3(time, id, temperature, status, duration) values(20000, 'd2', 26.4, false, 432000000)"
)

case_RN0317() {
  local st out unexpected=0
  for st in "${RN0317_SQL[@]}"; do
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
"TIMECHODB-0317 自动抽取|TIMECHODB-0317|功能|表模型】对于不支持ASOF RIGHT JOIN查询时，报305异常内部错误|case_RN0317"
)
