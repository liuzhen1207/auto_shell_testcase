#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0656
#   【TIMECHODB-0656】 使用模式匹配函数查询会出现索引越界的报错
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：可以正常查询显示结果 image.png  复现步骤 注册函数： create function pattern_match as 'org.apache.iotdb.library.match.UDAFPatternM
# ============================================================================
RN0656_SQL=(
"create function pattern_match as 'org.apache.iotdb.library.match.UDAFPatternMatch'"
"CREATE DATABASE root.db"
"create timeseries root.db.d0.s0 with datatype=INT32,encoding=PLAIN"
"create timeseries root.db.d0.s00 with datatype=INT32,encoding=PLAIN"
"create timeseries root.db.d0.s1 with datatype=INT64,encoding=PLAIN"
"create timeseries root.db.d0.s11 with datatype=INT64,encoding=PLAIN"
"create timeseries root.db.d0.s2 with datatype=FLOAT,encoding=PLAIN"
"create timeseries root.db.d0.s3 with datatype=DOUBLE,encoding=PLAIN"
"create timeseries root.db.d0.s4 with datatype=BOOLEAN,encoding=PLAIN"
"insert into root.db.d0 (timestamp,s0) values (1,1)"
"insert into root.db.d0 (timestamp,s0) values (2,2)"
"insert into root.db.d0 (timestamp,s0) values (3,3)"
"insert into root.db.d0 (timestamp,s0) values (4,3)"
"insert into root.db.d0 (timestamp,s0) values (5,3)"
"insert into root.db.d0 (timestamp,s0) values (6,3)"
"insert into root.db.d0 (timestamp,s1) values (1,1)"
"insert into root.db.d0 (timestamp,s1) values (2,2)"
"insert into root.db.d0 (timestamp,s1) values (3,3)"
"insert into root.db.d0 (timestamp,s2) values (1,1.1)"
"insert into root.db.d0 (timestamp,s2) values (2,2.2)"
"insert into root.db.d0 (timestamp,s2) values (3,3.3)"
"insert into root.db.d0 (timestamp,s3) values (1,1.1)"
"insert into root.db.d0 (timestamp,s3) values (2,2.2)"
"insert into root.db.d0 (timestamp,s3) values (3,3.3)"
"insert into root.db.d0 (timestamp,s4) values (1,true)"
"insert into root.db.d0 (timestamp,s4) values (2,true)"
"insert into root.db.d0 (timestamp,s4) values (3,false)"
"insert into root.db.d0 (timestamp,s0) values (-1,-1)"
"insert into root.db.d0 (timestamp,s0) values (-2,-2)"
"insert into root.db.d0 (timestamp,s0) values (-3,-3)"
"insert into root.db.d0 (timestamp,s00) values (2147483647,2147483647)"
"insert into root.db.d0 (timestamp,s00) values (-2147483648,-2147483648)"
"insert into root.db.d0 (timestamp,s2) values (4,1.123456)"
"insert into root.db.d0 (timestamp,s2) values (5,-2.123456)"
"insert into root.db.d0 (timestamp,s2) values (6,3.123456)"
"insert into root.db.d0 (timestamp,s3) values (4,1.1234567890123456)"
"insert into root.db.d0 (timestamp,s3) values (5,-2.1234567890123456)"
"insert into root.db.d0 (timestamp,s3) values (6,3.1234567890123456)"
"select s0 from root.db.d0"
"select s1 from root.db.d0"
"select s2 from root.db.d0"
"select s3 from root.db.d0"
"select s4 from root.db.d0"
"select pattern_match(s0, \"timePattern\"=\"4,5,6\", \"valuePattern\"=\"3,3,3\", \"threshold\"=\"0.0\") as match_result from root.db.d0"
)

case_RN0656() {
  local st out unexpected=0
  for st in "${RN0656_SQL[@]}"; do
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
"TIMECHODB-0656 自动抽取|TIMECHODB-0656|功能|使用模式匹配函数查询会出现索引越界的报错|case_RN0656"
)
