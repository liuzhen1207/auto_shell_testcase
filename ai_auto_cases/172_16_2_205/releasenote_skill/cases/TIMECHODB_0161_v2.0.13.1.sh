#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0161
#   【TIMECHODB-0161】 [权限]使用非root用户，有database的create,insert权限，却看不到该database，创建不了表
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：既然有 create,insert权限，就应该可以执行下列语句： create database, create table,  show databases, insert into table  复现步骤 -- 使用
# ============================================================================
RN0161_SQL=(
"create user user01 '1234'"
"grant create,insert on database \"汉化\" to user user01"
"show databases"
"list privileges of user user01"
"create database \"汉化\""
"list user"
)

case_RN0161() {
  local st out unexpected=0
  for st in "${RN0161_SQL[@]}"; do
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
"TIMECHODB-0161 自动抽取|TIMECHODB-0161|功能|权限]使用非root用户，有database的create,insert权限，却看不到该database，创建不了表|case_RN0161"
)
