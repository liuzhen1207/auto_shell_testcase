#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0240
#   【TIMECHODB-0240】 【表模型V2.0.3.1-RC1】Not Exists查询结果不正确
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表模型执行Not exists 查询结果集显示正确  复现步骤 启动1C1D 进入CLI，执行SQL操作  --1. 创建数据库 create database test_db;  --2. 指定数据库 use test
# ============================================================================
RN0240_SQL=(
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

case_RN0240() {
  local st out unexpected=0
  for st in "${RN0240_SQL[@]}"; do
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
"TIMECHODB-0240 自动抽取|TIMECHODB-0240|功能|表模型V2.0.3.1-RC1】Not Exists查询结果不正确|case_RN0240"
)
