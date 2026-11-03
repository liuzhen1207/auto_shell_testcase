#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0413
#   【TIMECHODB-0413】 【树模型-SQL】执行最新点查询数据丢失1条数据信息
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：执行最新点last查询，数据结果返回正确  复现步骤 （1）企业版：master分支 commitID：commit 3510f332a498cfe5167191b74a2badbb05e349a3 （2）启动1C1D 
# ============================================================================
RN0413_SQL=(
"create database root.sg"
"create aligned timeseries root.sg.d1(s1 float encoding=rle, s2 int64 encoding=rle)"
"create timeseries root.sg.d2.s1 with datatype=float,encoding=rle"
"create timeseries root.sg.d2.s2 with datatype=int64,encoding=rle"
"create device template t1 aligned (temperature FLOAT encoding=Gorilla, status BOOLEAN encoding=PLAIN)"
"set device template t1 to root.sg.aligned_template"
"create timeseries using device template on root.sg.aligned_template"
"create device template t2(temperature FLOAT encoding=Gorilla, status BOOLEAN encoding=PLAIN)"
"set device template t2 to root.sg.nonaligned_template"
"create timeseries using device template on root.sg.nonaligned_template"
"create view root.sg.view_d1.calculation as select (s1+s2)/2 from root.sg.d1"
"create view root.sg.view_d2.calculation as select sin(s1*s2) from root.sg.d2"
"insert into root.sg.d1(time,s1,s2) values(1,1,1),(2,2,2),(3,3,3)"
"insert into root.sg.d2(time,s1,s2) values(1,1,1),(2,2,2),(3,3,3)"
"insert into root.sg.aligned_template(time,temperature,status) values(1,20,false),(2,22.1,true),(3,18,false)"
"insert into root.sg.nonaligned_template(time,temperature,status) values(1,10.5,false),(2,0.1,true),(3,22.2,false)"
"CREATE USER user01 'pass1234'"
"GRANT WRITE ON root.** TO USER user01"
"create aligned timeseries root.sg.d1(s3 double encoding=rle, s4 int32 encoding=rle)"
"create timeseries root.sg.d2.s3 with datatype=INT32"
"create view root.sg.view_d1.s1 as select s1 from root.sg.d1"
"alter view root.sg.view_d1.s1 UPSERT TAGS(tag1=v1,tag2=v2) ATTRIBUTES(attr1=D1,attr2=D2)"
"select * from root.**"
"insert into root.sg.d1(time,s1,s2) values(4,4,4)"
"insert into root.sg.d2(time,s1,s2) values(4,4,4)"
"select last(*) from root.** order by timeseries"
)

case_RN0413() {
  local st out unexpected=0
  for st in "${RN0413_SQL[@]}"; do
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
"TIMECHODB-0413 自动抽取|TIMECHODB-0413|功能|树模型-SQL】执行最新点查询数据丢失1条数据信息|case_RN0413"
)
