#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0119
#   【TIMECHODB-0119】 Format函数中参数数量与pattern中格式化描述的不匹配当查询空表时不会报错，而Java.format执行同样操作会报错，实现效果不一致
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：会报错  复现步骤 create database test_db1; use test_db1; create table test_t1 (tag1 tag, attr1 attribute, s1 text); s
# ============================================================================
RN0119_SQL=(
"create database test_db1"
"create table test_t1 (tag1 tag, attr1 attribute, s1 text)"
"select format('%f %d',s1) from test_t1 order by time"
)

case_RN0119() {
  local st out unexpected=0
  for st in "${RN0119_SQL[@]}"; do
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
"TIMECHODB-0119 自动抽取|TIMECHODB-0119|功能|Format函数中参数数量与pattern中格式化描述的不匹配当查询空表时不会报错，而Java.format执行同样|case_RN0119"
)
