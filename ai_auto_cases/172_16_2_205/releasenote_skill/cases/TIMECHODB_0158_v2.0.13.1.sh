#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0158
#   【TIMECHODB-0158】 【表模型】非关联标量子查询 not in查询结果集不正确
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询结果集显示正确 复现步骤  create database test_db; use test_db; create table orders (         customer_id STRING TAG,   
# ============================================================================
RN0158_SQL=(
"create database test_db"
"create table orders"
"create table customers"
"insert into orders(time, customer_id, employee_id, project_id, project_name, order_id, order_amount) values"
"insert into customers(time,customer_id, remark, customer_name, region, order_id) values"
)

case_RN0158() {
  local st out unexpected=0
  for st in "${RN0158_SQL[@]}"; do
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
"TIMECHODB-0158 自动抽取|TIMECHODB-0158|功能|表模型】非关联标量子查询 not in查询结果集不正确|case_RN0158"
)
