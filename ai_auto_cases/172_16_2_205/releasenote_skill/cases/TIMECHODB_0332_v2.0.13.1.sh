#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0332
#   【TIMECHODB-0332】 【表模型V2.0.5.1-RC1】approx_most_frequent第2个参数为浮点数时，报301异常报错
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：approx_most_frequent第2个参数为浮点数时，报错提示显示正确  复现步骤 （1）启动1C1D （2）root用户进入CLI，执行SQL操作  --1.创建数据库 create database test
# ============================================================================
RN0332_SQL=(
"create database test_db"
"create table t1( ID TAG, attr ATTRIBUTE, int32 INT32, int64 INT64, boolean BOOLEAN, float FLOAT, double DOUBLE, text TEXT, string STRING, blob BLOB, timestamp TIMESTAMP, date DATE )"
"show tables"
"insert into t1( time, id, attr, int32, int64, boolean,float,double,text,string,blob,timestamp,date)"
)

case_RN0332() {
  local st out unexpected=0
  for st in "${RN0332_SQL[@]}"; do
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
"TIMECHODB-0332 自动抽取|TIMECHODB-0332|功能|表模型V2.0.5.1-RC1】approx_most_frequent第2个参数为浮点数时，报301异常报错|case_RN0332"
)
