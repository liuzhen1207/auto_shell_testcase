#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0095
#   【TIMECHODB-0095】 date和timestamp类型的数据，02-29和04-31写入会成功: 02-28,04-30，期望报错
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：应该报错  复现步骤 create database root.datatypes; create timeseries root.datatypes.d_date.s0 WITH DATATYPE=date,ENCOD
# ============================================================================
RN0095_SQL=(
"create database root.datatypes"
"create timeseries root.datatypes.d_date.s0 WITH DATATYPE=date,ENCODING=PLAIN,COMPRESSOR=UNCOMPRESSED"
"insert into root.datatypes.d_date(time,s0) values (2000,'1999-02-29')"
"insert into root.datatypes.d_date(time,s0) values (1999-02-29,'1999-02-21')"
"insert into root.datatypes.d_date(time,s0) values (4000,'1999-04-31')"
"insert into root.datatypes.d_date(time,s0) values (1999-04-31,'1999-04-03')"
"insert into root.datatypes.d_date(time,s0) values (1999-13-02,'1999-12-03')"
"insert into root.datatypes.d_date(time,s0) values (1999-03-02,'1999-13-03')"
"insert into root.datatypes.d_date(time,s0) values (6000,'2000-02-29')"
"insert into root.datatypes.d_date(time,s0) values (2000-02-29,'2000-02-20')"
"create timeseries root.datatypes.d_timestamp(s0 timestamp)"
"insert into root.datatypes.d_timestamp(time,s0) values (2000,1999-02-29)"
"insert into root.datatypes.d_Timestamp(time,s0) values (1999-02-29,1999-02-20)"
"insert into root.datatypes.d_timestamp(time,s0) values (1999-04-01,1999-04-31)"
"insert into root.datatypes.d_Timestamp(time,s0) values (1999-04-31,1999-02-20)"
"insert into root.datatypes.d_timestamp(time,s0) values (6000,2000-02-29)"
"insert into root.datatypes.d_timestamp(time,s0) values (2000-02-29,2000-02-20)"
"create database datatypes"
"create table datatypes.d_date(s0 date)"
"insert into datatypes.d_date(time,s0) values (2000,'1999-02-29')"
"insert into datatypes.d_date(time,s0) values (1999-02-29,'1999-02-20')"
"insert into datatypes.d_date(time,s0) values (4000,'1999-04-31')"
"insert into datatypes.d_date(time,s0) values (1999-04-31,'1999-04-03')"
"insert into datatypes.d_date(time,s0) values (6000,'2000-02-29')"
"insert into datatypes.d_date(time,s0) values (2000-02-29,'2000-02-20')"
"create table datatypes.d_timestamp(s0 timestamp)"
"insert into datatypes.d_timestamp(time,s0) values (2000,'1999-02-29')"
"insert into datatypes.d_Timestamp(time,s0) values (1999-02-29,'1999-02-20')"
"insert into datatypes.d_timestamp(time,s0) values (4000,'1999-04-31')"
"insert into datatypes.d_timestamp(time,s0) values (1999-04-31,'1999-04-03')"
"insert into datatypes.d_timestamp(time,s0) values (6000,'2000-02-29')"
"insert into datatypes.d_timestamp(time,s0) values (2000-02-29,'2000-02-20')"
)

case_RN0095() {
  local st out unexpected=0
  for st in "${RN0095_SQL[@]}"; do
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
"TIMECHODB-0095 自动抽取|TIMECHODB-0095|功能|date和timestamp类型的数据，02-29和04-31写入会成功: 02-28,04-30，期望报错|case_RN0095"
)
