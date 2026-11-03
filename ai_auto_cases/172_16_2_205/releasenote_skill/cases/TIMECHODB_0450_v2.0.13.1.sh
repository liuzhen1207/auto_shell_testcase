#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0450
#   【TIMECHODB-0450】 【表模型SQL】CASE WHEN执行查询时，报305服务内部错误异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：CASE WHEN执行查询时，返回正常的结果集信息  复现步骤 （1）开源版，master分支，commit 08ab2c9dcde2748165660a3308d058f63be1b80f （2）启动1C1D  （3）
# ============================================================================
RN0450_SQL=(
"create database test_db"
"create table table1 ( time TIMESTAMP TIME, region STRING TAG, device_id STRING TAG, model_id STRING ATTRIBUTE, maintenance STRING ATTRIBUTE, temperature FLOAT FIELD, humidity FLOAT FIELD, status Boolean FIELD, arrival_time TIMESTAMP FIELD )"
"show tables"
"desc table1"
"INSERT INTO table1(time, region, device_id, model_id, maintenance, temperature, humidity, status, arrival_time) VALUES"
)

case_RN0450() {
  local st out unexpected=0
  for st in "${RN0450_SQL[@]}"; do
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
"TIMECHODB-0450 自动抽取|TIMECHODB-0450|功能|表模型SQL】CASE WHEN执行查询时，报305服务内部错误异常|case_RN0450"
)
