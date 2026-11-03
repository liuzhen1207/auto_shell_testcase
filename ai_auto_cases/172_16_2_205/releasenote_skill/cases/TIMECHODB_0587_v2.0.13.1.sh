#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0587
#   【TIMECHODB-0587】 【表模型】插入数据后，若使用UPDATE更新表属性列为FIELD列会出现NPE
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：预期报错为不支持TIME/FIELD列  复现步骤  CREATE DATABASE test; USE test; CREATE TABLE table1(t1 STRING TAG, a1 STRING ATTRIB
# ============================================================================
RN0587_SQL=(
"CREATE DATABASE test"
"CREATE TABLE table1(t1 STRING TAG, a1 STRING ATTRIBUTE, s1 STRING FIELD)"
"DESC table1"
"INSERT INTO table1(time, t1, a1, s1) values(1, 't1', 'a1', 's1')"
"INSERT INTO table1(time, t1, a1, s1) values(2, 't1', 'a1', 's1')"
"INSERT INTO table1(time, t1, a1, s1) values(3, 't1', 'a1', 's1')"
"INSERT INTO table1(time, t1, a1, s1) values(4, 't1', 'a1', 's1')"
"INSERT INTO table1(time, t1, a1, s1) values(5, 't1', 'a1', 's1')"
"SELECT * FROM table1"
)

case_RN0587() {
  local st out unexpected=0
  for st in "${RN0587_SQL[@]}"; do
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
"TIMECHODB-0587 自动抽取|TIMECHODB-0587|功能|表模型】插入数据后，若使用UPDATE更新表属性列为FIELD列会出现NPE|case_RN0587"
)
