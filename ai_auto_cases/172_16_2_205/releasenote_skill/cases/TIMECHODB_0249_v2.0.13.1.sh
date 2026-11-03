#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0249
#   【TIMECHODB-0249】 SortNode 在分布式规划时被不正确消除
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：查询计划中存在 SortNode image.png  查询结果正确  +-------------+--------+ |department_id|dep_name| +-------------+--------+
# ============================================================================
RN0249_SQL=(
"create database test_db"
"create table employees"
"create table departments"
"create table customers"
"create table orders"
"show tables"
"insert into employees( time, department_id, remark, name, gender, status, employee_id, salary, date_of_birth, contac_info) values"
"insert into departments( time, department_id, dep_description, dep_name, dep_phone, dep_status, dep_member,employee_id) values"
"insert into orders(time, customer_id, employee_id, project_id, project_name, order_id, order_amount) values"
"insert into customers(time,customer_id, remark, customer_name, region, order_id) values"
"select department_id, dep_name from departments"
"select 1 from employees"
)

case_RN0249() {
  local st out unexpected=0
  for st in "${RN0249_SQL[@]}"; do
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
"TIMECHODB-0249 自动抽取|TIMECHODB-0249|功能|SortNode 在分布式规划时被不正确消除|case_RN0249"
)
