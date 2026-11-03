#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0297
#   【TIMECHODB-0297】 【UDTF】内置表值函数SESSION的TIMECOL参数缺少默认值，导致使用时不写TIMECOL会报错
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：需要添加默认值，使用SESSION时缺少TIMECOL也能正常使用  复现步骤  create database test; use test; create table test_session(t1 STRING T
# ============================================================================
RN0297_SQL=(
"create database test"
"create table test_session(t1 STRING TAG,a1 STRING ATTRIBUTE, s1 INT64 FIELD)"
"insert into test_session(time, t1, s1) values(5, 'AAPL', 100)"
"insert into test_session(time, t1, s1) values(6, 'TESL', 200)"
"insert into test_session(time, t1, s1) values(7, 'AAPL', 103)"
"insert into test_session(time, t1, s1) values(7, 'TESL', 202)"
"insert into test_session(time, t1, s1) values(9, 'AAPL', 102)"
"insert into test_session(time, t1, s1) values(15, 'TESL', 195)"
"SELECT * FROM SESSION(DATA => test_session PARTITION BY t1 ORDER BY time , GAP => 2ms)"
)

case_RN0297() {
  local st out unexpected=0
  for st in "${RN0297_SQL[@]}"; do
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
"TIMECHODB-0297 自动抽取|TIMECHODB-0297|功能|UDTF】内置表值函数SESSION的TIMECOL参数缺少默认值，导致使用时不写TIMECOL会报错|case_RN0297"
)
