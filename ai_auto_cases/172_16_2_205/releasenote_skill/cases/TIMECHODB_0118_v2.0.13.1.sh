#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0118
#   【TIMECHODB-0118】 Format函数中参数数量与pattern中格式化描述的不匹配报错会有两种信息，且日志会出现不符合预期的警告
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：只存在一种报错信息 应该直接在执行前就提示报错不执行，不会打印警告日志 复现步骤 create database test_db1; use test_db1; create table test_t1 (tag1 ta
# ============================================================================
RN0118_SQL=(
"create database test_db1"
"create table test_t1 (tag1 tag, attr1 attribute, s1 text)"
"insert into test_t1(time,tag1,attr1,s1) values(1,null,null,null)"
"select format('%f %d',s1) from test_t1 order by time"
)

case_RN0118() {
  local st out unexpected=0
  for st in "${RN0118_SQL[@]}"; do
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
"TIMECHODB-0118 自动抽取|TIMECHODB-0118|功能|Format函数中参数数量与pattern中格式化描述的不匹配报错会有两种信息，且日志会出现不符合预期的警告|case_RN0118"
)
