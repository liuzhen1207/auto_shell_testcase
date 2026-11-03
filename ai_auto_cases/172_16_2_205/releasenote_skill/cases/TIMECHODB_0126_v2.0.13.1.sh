#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0126
#   【TIMECHODB-0126】 【表模型SQL】数据类型DATE与INT32求和时，其返回状态码需更改
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：数据类型DATE+INT32，返回的状态码显示正确  复现步骤 开源版commitID：commit f9f0574b0f7b4a22793b87b43f020bffbb55c511 --1. 创建数据库 create 
# ============================================================================
RN0126_SQL=(
"create database test_db"
"create table table_add"
"INSERT INTO table_add"
"select date + int32 from table_add"
)

case_RN0126() {
  local st out unexpected=0
  for st in "${RN0126_SQL[@]}"; do
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
"TIMECHODB-0126 自动抽取|TIMECHODB-0126|功能|表模型SQL】数据类型DATE与INT32求和时，其返回状态码需更改|case_RN0126"
)
