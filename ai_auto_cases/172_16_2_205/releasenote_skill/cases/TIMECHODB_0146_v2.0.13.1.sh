#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0146
#   【TIMECHODB-0146】 【表模型-FULL JOIN】表达式全连接查询报305内部服务错误异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表达式全连接查询，结果集显示正常 复现步骤 create database test_db; use test_db; create table students (     region STRING TAG,    
# ============================================================================
RN0146_SQL=(
"create database test_db"
"create table students"
"create table teachers"
"create table courses"
"create table grades"
"insert into students(time,region,student_id,name,genders,date_of_birth) values"
"insert into teachers(time,region,teacher_id,course_id,age) values"
"insert into courses(time,course_region,course_id,course_name,teacher_id) values"
"insert into grades(time,grade_id,course_id,student_id,score) values"
"select * from"
)

case_RN0146() {
  local st out unexpected=0
  for st in "${RN0146_SQL[@]}"; do
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
"TIMECHODB-0146 自动抽取|TIMECHODB-0146|功能|表模型-FULL JOIN】表达式全连接查询报305内部服务错误异常|case_RN0146"
)
