#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0178
#   【TIMECHODB-0178】 【OPC-UA】表模型支持 NPE  && 多一层空级
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：复现步骤 问题1 create database timecho; use timecho; create table t1 (id1 tag,ab1 attribute, s1 int32); insert into 
# ============================================================================
RN0178_SQL=(
"create database timecho"
"create table t1 (id1 tag,ab1 attribute, s1 int32)"
"insert into t1(id1,ab1,s1) values('a','a',123)"
"alter table t1 add column s2 float"
"insert into t1(id1,ab1,s2) values('b','b',3.14)"
"alter table t1 add column s3 boolean"
"insert into t1(id1,ab1,s1,s2,s3) values('a','a',3,3.1415,0)"
"alter table t1 add column s4 date"
"insert into t1(s4) values('2025-12-25')"
"insert into t1(s1,s2,s3,s4) values(4,3.25,5555,'2025-12-25')"
"create table t1(a1 tag, s1 int32)"
"insert into t1(a1,s1) values('a',123)"
)

case_RN0178() {
  local st out unexpected=0
  for st in "${RN0178_SQL[@]}"; do
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
"TIMECHODB-0178 自动抽取|TIMECHODB-0178|功能|OPC-UA】表模型支持 NPE  && 多一层空级|case_RN0178"
)
