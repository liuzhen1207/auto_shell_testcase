#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0059
#   【TIMECHODB-0059】 删除数据后，触发合并时会导致已删除数据再次被查询
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：
# ============================================================================
RN0059_SQL=(
"select time,country,region,city,device,ab1,s1,s2,s3,s4 from t1 order by time"
"create database if not exists db1"
"create table t1(country TAG,region TAG, city TAG, device TAG, ab1 ATTRIBUTE, s1 int32, s2 float, s3 boolean, s4 string)"
"INSERT INTO t1(time,country,region,city,device,ab1,s1,s2,s3,s4) values"
"delete from t1"
"drop table t1"
"delete from t1 where time < 110"
"delete from t1 where time <=200"
"delete from t1 where time >1220"
"delete from t1 where time <=1200 and time >=1100"
"delete from t1 where time <=1001 and time >999"
"delete from t1 where time <999 and time >=900"
"delete from t1 where time <888 and time >777"
"delete from t1 where time >444 and time <666"
"delete from t1 where time <333 or time >666"
"delete from t1 where country='japan'"
"delete from t1 where country='china' and region='beijing'"
"delete from t1 where country='china' and region='hebei' and time > 99 and time < 250"
"delete from t1 where country='china'"
)

case_RN0059() {
  local st out unexpected=0
  for st in "${RN0059_SQL[@]}"; do
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
"TIMECHODB-0059 自动抽取|TIMECHODB-0059|功能|删除数据后，触发合并时会导致已删除数据再次被查询|case_RN0059"
)
