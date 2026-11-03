#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0351
#   【TIMECHODB-0351】 【表模型V2.0.5.1-RC2】MATCH_RECOGNIZE执行查询过程中遇到time out 超时
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：MATCH_RECOGNIZE执行查询，结果集返回正常且正确  复现步骤 （1）启动1C1D （2）root用户，进入CLI执行SQL操作  --1.创建数据库 create database test_db;  --2
# ============================================================================
RN0351_SQL=(
"create database test_db"
"create table orders( customer_id TAG, region ATTRIBUTE, order_date DATE, product TEXT, status BOOLEAN, number INT64, totalprice DOUBLE)"
"show tables"
"desc orders"
"insert into orders( time, customer_id, region, order_date, product, status, number, totalprice ) values"
)

case_RN0351() {
  local st out unexpected=0
  for st in "${RN0351_SQL[@]}"; do
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
"TIMECHODB-0351 自动抽取|TIMECHODB-0351|功能|表模型V2.0.5.1-RC2】MATCH_RECOGNIZE执行查询过程中遇到time out 超时|case_RN0351"
)
